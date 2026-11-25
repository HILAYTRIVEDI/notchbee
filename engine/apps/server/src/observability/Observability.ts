import * as Layer from "effect/Layer";
import * as References from "effect/References";

import * as ServerLogger from "../serverLogger.ts";

export const layer = Layer.merge(
  ServerLogger.layer,
  Layer.succeed(References.TracerEnabled, false),
);
