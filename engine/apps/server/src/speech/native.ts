import type { SpeechStreamText } from "@t3tools/contracts";

interface NativeSpeechModel {
  readonly backend: string;
  readonly languages: readonly string[];
  readonly supportsStreaming: boolean;
  readonly supportsLongForm: boolean;
  readonly supportsTranslation: boolean;
  readonly supportsVocabulary: boolean;
  readonly begin: (options: NativeSpeechOptions, filterSilence: boolean, vadPath?: string) => Promise<void>;
  readonly feed: (pcm: Float32Array) => Promise<{ revision: number; text: SpeechStreamText | null }>;
  readonly finish: () => Promise<string>;
  readonly reset: () => Promise<void>;
  readonly transcribe: (pcm: Float32Array, options: NativeSpeechOptions, filterSilence: boolean, vadPath?: string) => Promise<{ text: string }>;
  readonly dispose: () => Promise<void>;
}

export async function listNativeSpeechGpuDevices(): Promise<ReadonlyArray<{ id: string; name: string }>> {
  return [];
}

export async function loadNativeSpeechModel(
  _path: string,
  _signal: AbortSignal,
  _moduleUrl?: string,
  _acceleration = "auto",
): Promise<NativeSpeechModel> {
  throw new Error("Native audio transcription is unavailable in this engine.");
}

type NativeSpeechOptions = {
  readonly timestamps: "none";
  readonly task?: "translate";
  readonly targetLanguage?: "en";
  readonly language?: string;
  readonly vocabulary?: readonly string[];
};
