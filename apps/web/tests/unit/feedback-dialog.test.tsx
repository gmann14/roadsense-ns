import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

import { FeedbackDialog } from "@/components/feedback/feedback-dialog";

vi.mock("next/navigation", () => ({
  usePathname: () => "/reports/potholes",
}));

const submitFeedbackMock = vi.hoisted(() => vi.fn());

vi.mock("@/lib/api/client", () => ({
  submitFeedback: submitFeedbackMock,
}));

beforeEach(() => {
  submitFeedbackMock.mockReset();

  if (typeof HTMLDialogElement !== "undefined") {
    HTMLDialogElement.prototype.showModal = function showModal() {
      this.setAttribute("open", "");
    };
    HTMLDialogElement.prototype.close = function close() {
      this.removeAttribute("open");
      this.dispatchEvent(new Event("close"));
    };
  }
});

afterEach(() => {
  cleanup();
});

describe("FeedbackDialog", () => {
  it("disables submit until message length and email validity are satisfied", async () => {
    render(<FeedbackDialog />);

    fireEvent.click(screen.getByTestId("open-feedback"));
    const submit = screen.getByTestId("feedback-submit");
    expect(submit).toBeDisabled();

    fireEvent.change(screen.getByTestId("feedback-message"), {
      target: { value: "short" },
    });
    expect(submit).toBeDisabled();

    fireEvent.change(screen.getByTestId("feedback-message"), {
      target: { value: "Map froze when I tapped Mark pothole twice in a row." },
    });
    expect(submit).not.toBeDisabled();

    fireEvent.click(screen.getByTestId("feedback-consent"));
    expect(submit).toBeDisabled();

    fireEvent.change(screen.getByTestId("feedback-email"), {
      target: { value: "not-an-email" },
    });
    expect(submit).toBeDisabled();

    fireEvent.change(screen.getByTestId("feedback-email"), {
      target: { value: "tester@example.com" },
    });
    expect(submit).not.toBeDisabled();
  });

  it("submits with the active route, locale, and trimmed values", async () => {
    submitFeedbackMock.mockResolvedValueOnce({ kind: "accepted", id: "abc", requestId: "req-1" });

    render(<FeedbackDialog />);

    fireEvent.click(screen.getByTestId("open-feedback"));
    fireEvent.change(screen.getByTestId("feedback-message"), {
      target: { value: "  Found stale pothole on Quinpool Rd  " },
    });
    fireEvent.change(screen.getByTestId("feedback-email"), {
      target: { value: "tester@example.com" },
    });
    fireEvent.click(screen.getByTestId("feedback-consent"));
    fireEvent.click(screen.getByTestId("feedback-submit"));

    await waitFor(() => {
      expect(submitFeedbackMock).toHaveBeenCalledTimes(1);
    });

    const callArg = submitFeedbackMock.mock.calls[0][0];
    expect(callArg.category).toBe("bug");
    expect(callArg.message).toBe("Found stale pothole on Quinpool Rd");
    expect(callArg.replyEmail).toBe("tester@example.com");
    expect(callArg.contactConsent).toBe(true);
    expect(callArg.route).toBe("/reports/potholes");

    await waitFor(() => {
      expect(screen.getByTestId("feedback-status").textContent).toContain("Thanks");
    });
  });

  it("surfaces validation errors returned from the server", async () => {
    submitFeedbackMock.mockResolvedValueOnce({
      kind: "validation_failed",
      fieldErrors: { message: "must be at least 8 characters" },
      requestId: "req-2",
    });

    render(<FeedbackDialog />);
    fireEvent.click(screen.getByTestId("open-feedback"));
    fireEvent.change(screen.getByTestId("feedback-message"), {
      target: { value: "edge case message that passes client checks but fails server" },
    });
    fireEvent.click(screen.getByTestId("feedback-submit"));

    await waitFor(() => {
      expect(screen.getByTestId("feedback-status").textContent).toContain("must be at least 8 characters");
    });
  });

  it("surfaces a rate-limit message when the server returns 429", async () => {
    submitFeedbackMock.mockResolvedValueOnce({
      kind: "rate_limited",
      retryAfterSeconds: 1800,
      requestId: "req-3",
    });

    render(<FeedbackDialog />);
    fireEvent.click(screen.getByTestId("open-feedback"));
    fireEvent.change(screen.getByTestId("feedback-message"), {
      target: { value: "trying again after the rate limit." },
    });
    fireEvent.click(screen.getByTestId("feedback-submit"));

    await waitFor(() => {
      const text = screen.getByTestId("feedback-status").textContent ?? "";
      expect(text).toContain("Too many submissions");
      expect(text).toContain("30");
    });
  });

  it("keeps form state when the network call fails", async () => {
    submitFeedbackMock.mockResolvedValueOnce({
      kind: "network_error",
      message: "fetch failed",
    });

    render(<FeedbackDialog />);
    fireEvent.click(screen.getByTestId("open-feedback"));
    fireEvent.change(screen.getByTestId("feedback-message"), {
      target: { value: "Couldn't reach the function — retry test." },
    });
    fireEvent.click(screen.getByTestId("feedback-submit"));

    await waitFor(() => {
      expect(screen.getByTestId("feedback-status").textContent).toContain("Couldn't reach RoadSense");
    });

    expect((screen.getByTestId("feedback-message") as HTMLTextAreaElement).value).toBe(
      "Couldn't reach the function — retry test.",
    );
  });
});
