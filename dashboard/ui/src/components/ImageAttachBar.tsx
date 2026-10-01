import { useRef } from "react";
import { MAX_IMAGES, type PendingImage } from "../imageAttachments";

/** Attach button (file picker / camera on the phone) + thumbnails with remove.
 *  Paste is wired on the text field itself (see `imagesFromClipboard`).
 *  `canAdd={false}` (a target on another machine) hides the attach button but
 *  keeps any thumbnails removable. */
export function ImageAttachBar({
  images,
  error,
  disabled,
  canAdd = true,
  onAdd,
  onRemove,
}: {
  images: PendingImage[];
  error: string | null;
  disabled?: boolean;
  canAdd?: boolean;
  onAdd: (files: File[]) => void;
  onRemove: (key: string) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  return (
    <div className="image-attach-bar">
      {canAdd && (
        <button
          type="button"
          className="image-attach-button"
          aria-label="attach image"
          disabled={disabled || images.length >= MAX_IMAGES}
          onClick={() => input.current?.click()}
        >
          📎 Image
        </button>
      )}
      <input
        ref={input}
        type="file"
        accept="image/*"
        multiple
        hidden
        onChange={(e) => {
          const files = Array.from(e.currentTarget.files ?? []);
          e.currentTarget.value = "";
          if (files.length) onAdd(files);
        }}
      />
      {images.map((img) => (
        <span key={img.key} className="image-attach-thumb">
          <img src={img.url} alt="attached" />
          <button type="button" aria-label="remove image" disabled={disabled} onClick={() => onRemove(img.key)}>
            ×
          </button>
        </span>
      ))}
      {error && <span className="image-attach-error">{error}</span>}
    </div>
  );
}
