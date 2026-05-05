import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { MethodologyContent } from "@/components/content/methodology-content";
import { PrivacyContent } from "@/components/content/privacy-content";

afterEach(() => {
  cleanup();
});

describe("content pages", () => {
  it("renders the editorial hero copy", () => {
    render(<MethodologyContent />);
    expect(
      screen.getByText(/Every line on the map is a real drive on a real road/i),
    ).toBeInTheDocument();
  });

  it("renders the table of contents pills with numbered labels", () => {
    render(<MethodologyContent />);
    expect(screen.getByRole("link", { name: /01 · Collection/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /02 · Aggregation/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /03 · Confidence/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /04 · Refresh/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /05 · What it isn't/i })).toBeInTheDocument();
  });

  it("renders a 4-step collection pipeline diagram", () => {
    const { container } = render(<MethodologyContent />);
    expect(container.querySelectorAll(".pipeline-step")).toHaveLength(4);
    expect(screen.getByText(/Phone records/i)).toBeInTheDocument();
    expect(screen.getByText(/Public aggregate/i)).toBeInTheDocument();
  });

  it("renders a 3-tier confidence diagram", () => {
    const { container } = render(<MethodologyContent />);
    const tiers = container.querySelectorAll(".confidence-tier");
    expect(tiers).toHaveLength(3);
    const labels = Array.from(container.querySelectorAll(".confidence-tier-label")).map(
      (node) => node.textContent,
    );
    expect(labels).toEqual(["Low confidence", "Medium confidence", "High confidence"]);
  });

  it("renders the 'What this isn't' negative-space list", () => {
    const { container } = render(<MethodologyContent />);
    const items = container.querySelectorAll(".method-not-list li");
    expect(items.length).toBe(4);
    expect(screen.getByText(/Not a maintenance queue/i)).toBeInTheDocument();
    expect(screen.getByText(/Not a 911 substitute/i)).toBeInTheDocument();
    expect(screen.getByText(/Not surveillance/i)).toBeInTheDocument();
    expect(screen.getByText(/Not a complete map/i)).toBeInTheDocument();
  });

  it("renders privacy trust copy", () => {
    render(<PrivacyContent />);

    expect(screen.getByText(/filters privacy zones on-device before upload/i)).toBeInTheDocument();
    expect(screen.getByText(/does not use ad trackers or session replay tools/i)).toBeInTheDocument();
    expect(screen.getByText(/raw drive samples are kept for up to 6 months/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /graham\.mann14@gmail\.com/i })).toHaveAttribute(
      "href",
      "mailto:graham.mann14@gmail.com",
    );
  });
});
