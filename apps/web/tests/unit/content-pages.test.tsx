import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { MethodologyContent } from "@/components/content/methodology-content";
import { PrivacyContent } from "@/components/content/privacy-content";

describe("content pages", () => {
  it("renders methodology trust copy", () => {
    render(<MethodologyContent />);

    expect(
      screen.getByText(/the server, not the phone, matches each accepted reading to a road segment/i),
    ).toBeInTheDocument();
    expect(screen.getByText(/data is refreshed in batches instead of pretending to be live/i)).toBeInTheDocument();
  });

  it("renders privacy trust copy", () => {
    render(<PrivacyContent />);

    expect(screen.getByText(/filters privacy zones on-device before upload/i)).toBeInTheDocument();
    expect(screen.getByText(/does not use ad trackers or session replay tools/i)).toBeInTheDocument();
    expect(screen.getByText(/raw readings are kept for up to 6 months/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /graham\.mann14@gmail\.com/i })).toHaveAttribute(
      "href",
      "mailto:graham.mann14@gmail.com",
    );
  });
});
