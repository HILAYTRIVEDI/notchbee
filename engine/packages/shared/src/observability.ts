import * as Cause from "effect/Cause";
import * as Option from "effect/Option";


export type TraceAttributes = Readonly<Record<string, unknown>>;

function isStructuralTag(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= 128 &&
    /^[A-Za-z][A-Za-z0-9._:/-]*$/.test(value)
  );
}

export function errorTag(error: unknown): string {
  try {
    if (typeof error === "object" && error !== null && "_tag" in error) {
      return isStructuralTag(error._tag) ? error._tag : "TaggedError";
    }
    if (error instanceof Error) {
      return isStructuralTag(error.name) ? error.name : "Error";
    }
  } catch {
    return "UnknownError";
  }
  return typeof error;
}

export function causeErrorTag(cause: Cause.Cause<unknown>): string {
  const failure = Cause.findErrorOption(cause);
  if (Option.isSome(failure)) {
    return errorTag(failure.value);
  }
  return cause.reasons[0]?._tag ?? "Empty";
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Repeated references expand once per path, so a small shared graph can grow exponentially.
const TRACE_ATTRIBUTE_MAX_NODES = 10_000;

interface NormalizeState {
  // Only the current ancestors, so a value repeated under two keys is not a cycle.
  readonly seen: WeakSet<object>;
  remainingNodes: number;
}

function enterNode(value: object, state: NormalizeState): string | undefined {
  if (state.seen.has(value)) {
    return "[Circular]";
  }
  if (state.remainingNodes <= 0) {
    return "[Truncated]";
  }
  state.remainingNodes--;
  state.seen.add(value);
  return undefined;
}

function normalizeJsonValue(value: unknown, state: NormalizeState): unknown {
  if (
    value === null ||
    value === undefined ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return value ?? null;
  }
  if (typeof value === "bigint") {
    return value.toString();
  }
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? "Invalid Date" : value.toISOString();
  }
  if (value instanceof Error) {
    return {
      name: value.name,
      message: value.message,
      ...(value.stack ? { stack: value.stack } : {}),
    };
  }
  if (Array.isArray(value)) {
    const marker = enterNode(value, state);
    if (marker) {
      return marker;
    }
    const normalized = value.map((entry) => normalizeJsonValue(entry, state));
    state.seen.delete(value);
    return normalized;
  }
  if (value instanceof Map) {
    const marker = enterNode(value, state);
    if (marker) {
      return marker;
    }
    const normalized = Object.fromEntries(
      Array.from(value.entries(), ([key, entryValue]) => [
        String(key),
        normalizeJsonValue(entryValue, state),
      ]),
    );
    state.seen.delete(value);
    return normalized;
  }
  if (value instanceof Set) {
    const marker = enterNode(value, state);
    if (marker) {
      return marker;
    }
    const normalized = Array.from(value.values(), (entry) => normalizeJsonValue(entry, state));
    state.seen.delete(value);
    return normalized;
  }
  if (!isPlainObject(value)) {
    return String(value);
  }
  const marker = enterNode(value, state);
  if (marker) {
    return marker;
  }
  const normalized = Object.fromEntries(
    Object.entries(value).map(([key, entryValue]) => [key, normalizeJsonValue(entryValue, state)]),
  );
  state.seen.delete(value);
  return normalized;
}

export function compactTraceAttributes(
  attributes: Readonly<Record<string, unknown>>,
): TraceAttributes {
  const state: NormalizeState = { seen: new WeakSet(), remainingNodes: TRACE_ATTRIBUTE_MAX_NODES };
  const entries: Array<[string, unknown]> = [];
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== undefined) {
      entries.push([key, normalizeJsonValue(value, state)]);
    }
  }
  return Object.fromEntries(entries);
}

const URL_CREDENTIAL_PARAMS = /(^|[?&"\s])(wsTicket|dpop)=[^&#"\\\s]*/g;

const redactUrlCredentials = (text: string) =>
  text.replace(URL_CREDENTIAL_PARAMS, "$1$2=<redacted>");

export function redactCauseCredentials(cause: Cause.Cause<unknown>): Cause.Cause<unknown> {
  if (cause.reasons.length === 0 || Cause.hasInterruptsOnly(cause)) {
    return cause;
  }
  const pretty = Cause.pretty(cause);
  const redacted = redactUrlCredentials(pretty);
  return redacted === pretty ? cause : Cause.die(new Error(redacted));
}
