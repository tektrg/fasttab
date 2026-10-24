import { useRef } from "react";
import { MAX_IMAGES, type PendingImage } from "../imageAttachments";
import { IconButton } from "../ui/IconButton";

/** Attach button (file picker / camera on the phone) + thumbnails with remove.
 *  `compact` (phone composer) leaves the button to `AttachImageButton` next to
 *  the field and renders only the thumbnails / error, or nothing at all.
 *  Paste is wired on the text field itself (see `imagesFromClipboard`).
 *  `canAdd={false}` (a target on another machine) hides the attach button but
 *  keeps any thumbnails removable. */
/** 44px paperclip icon button + its hidden file input. */
export function AttachImageButton({
  count,
  disabled,
  onAdd,
}: {
  count: number;
  disabled?: boolean;
  onAdd: (files: File[]) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  return (
    <>
      <IconButton aria-label="attach image" disabled={disabled || count >= MAX_IMAGES} onClick={() => input.current?.click()}>
        <span aria-hidden="true">📎</span>
      </IconButton>
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
    </>
  );
}

export function ImageAttachBar({
  images,
  error,
  disabled,
  canAdd = true,
  compact,
  onAdd,
  onRemove,
}: {
  images: PendingImage[];
  error: string | null;
  disabled?: boolean;
  canAdd?: boolean;
  compact?: boolean;
  onAdd: (files: File[]) => void;
  onRemove: (key: string) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  if (compact && images.length === 0 && !error) return null;
  return (
    <div className="image-attach-bar">
      {canAdd && !compact && (
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
      {!compact && (
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
      )}
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
