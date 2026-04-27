"use client";

import { useEffect, useId, useRef, useState } from "react";
import { usePathname } from "next/navigation";

import {
  type FeedbackCategoryValue,
  type FeedbackSubmissionOutcome,
  submitFeedback,
} from "@/lib/api/client";

type Props = {
  triggerLabel?: string;
  triggerClassName?: string;
};

const MESSAGE_MIN = 8;
const MESSAGE_MAX = 4000;

const CATEGORY_OPTIONS: Array<{ value: FeedbackCategoryValue; label: string }> = [
  { value: "bug", label: "Bug or crash" },
  { value: "feature", label: "Feature suggestion" },
  { value: "map_issue", label: "Map or road data issue" },
  { value: "pothole_issue", label: "Pothole issue" },
  { value: "privacy_safety", label: "Privacy or safety concern" },
  { value: "other", label: "Something else" },
];

type Status =
  | { kind: "idle" }
  | { kind: "submitting" }
  | { kind: "submitted" }
  | { kind: "error"; message: string }
  | { kind: "validation"; fieldErrors: Record<string, string> }
  | { kind: "rate_limited"; retryAfterSeconds: number | null };

export function FeedbackDialog({
  triggerLabel = "Send feedback",
  triggerClassName,
}: Props) {
  const pathname = usePathname();
  const dialogRef = useRef<HTMLDialogElement>(null);
  const messageId = useId();
  const emailId = useId();
  const consentId = useId();

  const [isOpen, setIsOpen] = useState(false);
  const [category, setCategory] = useState<FeedbackCategoryValue>("bug");
  const [message, setMessage] = useState("");
  const [replyEmail, setReplyEmail] = useState("");
  const [contactConsent, setContactConsent] = useState(false);
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (isOpen && !dialog.open) {
      dialog.showModal();
    } else if (!isOpen && dialog.open) {
      dialog.close();
    }
  }, [isOpen]);

  const trimmedMessage = message.trim();
  const trimmedEmail = replyEmail.trim();
  const isEmailValid = trimmedEmail.length === 0 || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmedEmail);
  const canSubmit =
    status.kind !== "submitting" &&
    trimmedMessage.length >= MESSAGE_MIN &&
    trimmedMessage.length <= MESSAGE_MAX &&
    isEmailValid &&
    (!contactConsent || trimmedEmail.length > 0);

  function close() {
    setIsOpen(false);
  }

  function reset() {
    setCategory("bug");
    setMessage("");
    setReplyEmail("");
    setContactConsent(false);
    setStatus({ kind: "idle" });
  }

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canSubmit) return;

    setStatus({ kind: "submitting" });
    const outcome = await submitFeedback({
      category,
      message: trimmedMessage,
      replyEmail: trimmedEmail,
      contactConsent,
      route: pathname ?? "/",
      locale: typeof navigator !== "undefined" ? navigator.language : null,
    });

    setStatus(translateOutcome(outcome));
  }

  return (
    <>
      <button
        type="button"
        className={triggerClassName ?? "top-nav-link"}
        onClick={() => {
          reset();
          setIsOpen(true);
        }}
        data-testid="open-feedback"
      >
        {triggerLabel}
      </button>

      <dialog
        ref={dialogRef}
        className="feedback-dialog"
        aria-labelledby="feedback-dialog-title"
        onClose={() => setIsOpen(false)}
      >
        <form method="dialog" onSubmit={handleSubmit} className="feedback-form">
          <header className="feedback-form-header">
            <h2 id="feedback-dialog-title">Send feedback</h2>
            <button
              type="button"
              onClick={close}
              className="feedback-close"
              aria-label="Close feedback form"
            >
              ×
            </button>
          </header>

          <p className="feedback-privacy-note">
            We don&apos;t include your location, drive data, or device ID. We do
            attach your browser version and the page you came from so a tester
            report is reproducible.
          </p>

          <fieldset className="feedback-field-set">
            <legend>What&apos;s it about?</legend>
            <div className="feedback-categories">
              {CATEGORY_OPTIONS.map((option) => (
                <label key={option.value} className="feedback-category-option">
                  <input
                    type="radio"
                    name="feedback-category"
                    value={option.value}
                    checked={category === option.value}
                    onChange={() => setCategory(option.value)}
                  />
                  <span>{option.label}</span>
                </label>
              ))}
            </div>
          </fieldset>

          <div className="feedback-field">
            <label htmlFor={messageId}>What happened?</label>
            <textarea
              id={messageId}
              value={message}
              onChange={(event) => setMessage(event.target.value)}
              minLength={MESSAGE_MIN}
              maxLength={MESSAGE_MAX}
              rows={6}
              required
              data-testid="feedback-message"
            />
            <p className="feedback-helper">
              At least {MESSAGE_MIN} characters. {trimmedMessage.length}/{MESSAGE_MAX}
            </p>
          </div>

          <div className="feedback-field">
            <label htmlFor={emailId}>Reply email (optional)</label>
            <input
              id={emailId}
              type="email"
              value={replyEmail}
              onChange={(event) => setReplyEmail(event.target.value)}
              autoComplete="email"
              data-testid="feedback-email"
            />
            <label htmlFor={consentId} className="feedback-consent">
              <input
                id={consentId}
                type="checkbox"
                checked={contactConsent}
                onChange={(event) => setContactConsent(event.target.checked)}
                data-testid="feedback-consent"
              />
              <span>OK to email me about this report</span>
            </label>
          </div>

          {renderStatusBanner(status)}

          <div className="feedback-actions">
            <button type="button" onClick={close} className="feedback-secondary">
              Cancel
            </button>
            <button
              type="submit"
              disabled={!canSubmit}
              className="feedback-primary"
              data-testid="feedback-submit"
            >
              {status.kind === "submitting" ? "Sending…" : "Send"}
            </button>
          </div>
        </form>
      </dialog>
    </>
  );
}

function translateOutcome(outcome: FeedbackSubmissionOutcome): Status {
  switch (outcome.kind) {
    case "accepted":
      return { kind: "submitted" };
    case "validation_failed":
      return { kind: "validation", fieldErrors: outcome.fieldErrors };
    case "rate_limited":
      return { kind: "rate_limited", retryAfterSeconds: outcome.retryAfterSeconds };
    case "network_error":
      return { kind: "error", message: outcome.message };
    case "server_error":
      return { kind: "error", message: `Server error ${outcome.statusCode}.` };
  }
}

function renderStatusBanner(status: Status) {
  if (status.kind === "idle" || status.kind === "submitting") {
    return null;
  }

  if (status.kind === "submitted") {
    return (
      <p className="feedback-banner feedback-banner-success" data-testid="feedback-status">
        Thanks — feedback received. You can close this dialog now.
      </p>
    );
  }

  if (status.kind === "validation") {
    const errors = Object.values(status.fieldErrors).sort();
    return (
      <p className="feedback-banner feedback-banner-warning" data-testid="feedback-status">
        Couldn&apos;t send that yet:
        {" "}
        {errors.length > 0 ? errors.join(" · ") : "please review the form."}
      </p>
    );
  }

  if (status.kind === "rate_limited") {
    const minutes = status.retryAfterSeconds
      ? Math.max(1, Math.ceil(status.retryAfterSeconds / 60))
      : null;
    return (
      <p className="feedback-banner feedback-banner-warning" data-testid="feedback-status">
        Too many submissions from this network.
        {minutes ? ` Try again in about ${minutes} minute${minutes === 1 ? "" : "s"}.` : " Try again in a few minutes."}
      </p>
    );
  }

  return (
    <p className="feedback-banner feedback-banner-danger" data-testid="feedback-status">
      Couldn&apos;t reach RoadSense. Your form is still here — try sending again.
      <span className="feedback-banner-detail"> ({status.message})</span>
    </p>
  );
}
