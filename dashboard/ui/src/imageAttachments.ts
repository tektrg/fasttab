import { useCallback, useEffect, useRef, useState } from "react";
import { LOGGED_OUT_ERROR } from "./api";

/** Image attachments for Send message. The server stores each image and
 *  appends its file path to the text (the Claude peer socket drops image
 *  blocks), so the flow is: downscale here -> POST /api/attachments/image
 *  (raw bytes) -> send the returned ids with the message. Limits mirror
 *  server/lib/image_attachments.py. */
export const MAX_IMAGES = 4;
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export const MAX_LONG_EDGE = 2048;
const SENDABLE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

export interface PendingImage {
  key: string;
  blob: Blob;
  /** object URL for the thumbnail; revoked on remove/clear/unmount. */
  url: string;
}

/** Target size for an image: long edge capped at MAX_LONG_EDGE. */
export function fitWithin(width: number, height: number, max = MAX_LONG_EDGE) {
  const factor = Math.min(1, max / Math.max(width, height));
  return { width: Math.max(1, Math.round(width * factor)), height: Math.max(1, Math.round(height * factor)) };
}

/** Sends as-is when already small enough and a type the server takes;
 *  otherwise redraws on a canvas at <= 2048px as JPEG (lower quality while
 *  over 5 MB). Throws when the browser can't decode it. */
export async function downscaleImage(file: Blob): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const size = fitWithin(bitmap.width, bitmap.height);
  const fits = size.width === bitmap.width && size.height === bitmap.height;
  if (fits && file.size <= MAX_IMAGE_BYTES && SENDABLE_TYPES.includes(file.type)) {
    bitmap.close?.();
    return file;
  }
  const canvas = document.createElement("canvas");
  canvas.width = size.width;
  canvas.height = size.height;
  canvas.getContext("2d")?.drawImage(bitmap, 0, 0, size.width, size.height);
  bitmap.close?.();
  for (const quality of [0.85, 0.7, 0.5]) {
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
    if (blob && blob.size <= MAX_IMAGE_BYTES) return blob;
  }
  throw new Error("image stays over 5 MB");
}

/** Uploads every image in order: all ids, or the first failure (nothing is sent then). */
export async function uploadImages(blobs: Blob[]): Promise<{ ok: true; ids: string[] } | { ok: false; error: string }> {
  const ids: string[] = [];
  for (const blob of blobs) {
    try {
      const r = await fetch("/api/attachments/image", {
        method: "POST",
        headers: { "Content-Type": blob.type || "image/jpeg" },
        body: blob,
      });
      if (r.status === 401) return { ok: false, error: LOGGED_OUT_ERROR };
      const res = (await r.json()) as { ok?: boolean; id?: string; error?: string };
      if (!res.ok || !res.id) return { ok: false, error: res.error || "the dashboard refused the image" };
      ids.push(res.id);
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }
  return { ok: true, ids };
}

/** The image files in a paste (screenshots, copied photos). */
export function imagesFromClipboard(data: DataTransfer | null): File[] {
  return Array.from(data?.files ?? []).filter((f) => f.type.startsWith("image/"));
}

let nextKey = 0;

/** Draft images for one composer: add (downscaled), remove, clear. */
export function useImageAttachments() {
  const [images, setImages] = useState<PendingImage[]>([]);
  const [error, setError] = useState<string | null>(null);
  const live = useRef(images);
  live.current = images;
  useEffect(() => () => live.current.forEach((i) => URL.revokeObjectURL(i.url)), []);

  const add = useCallback(async (files: File[]) => {
    setError(null);
    const room = MAX_IMAGES - live.current.length;
    if (files.length > room) setError(`At most ${MAX_IMAGES} images per message.`);
    const added: PendingImage[] = [];
    for (const file of files.slice(0, Math.max(0, room))) {
      try {
        const blob = await downscaleImage(file);
        added.push({ key: `img-${nextKey++}`, blob, url: URL.createObjectURL(blob) });
      } catch {
        setError("Couldn't read that image.");
      }
    }
    if (added.length) setImages((prev) => [...prev, ...added].slice(0, MAX_IMAGES));
  }, []);

  const remove = useCallback((key: string) => {
    setImages((prev) => {
      prev.filter((i) => i.key === key).forEach((i) => URL.revokeObjectURL(i.url));
      return prev.filter((i) => i.key !== key);
    });
  }, []);

  const clear = useCallback(() => {
    setImages((prev) => {
      prev.forEach((i) => URL.revokeObjectURL(i.url));
      return [];
    });
    setError(null);
  }, []);

  return { images, error, setError, add, remove, clear };
}
