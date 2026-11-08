import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SegmentDrawerPanel } from "@/components/map/segment-drawer";

afterEach(() => {
  cleanup();
});

type PanelOverrides = Partial<Parameters<typeof SegmentDrawerPanel>[0]>;

function panel(overrides: PanelOverrides = {}) {
  return (
    <SegmentDrawerPanel
      mode="quality"
      selectedSegmentId="seg-1"
      detail={null}
      potholes={[]}
      topPotholes={[]}
      isLoading={false}
      errorMessage={null}
      onClearSelection={vi.fn()}
      onPotholeLocate={vi.fn()}
      isOpen
      onClose={vi.fn()}
      {...overrides}
    />
  );
}

describe("segment drawer focus management", () => {
  it("focuses the close button when the drawer opens", () => {
    const { rerender } = render(panel({ isOpen: false }));
    expect(screen.getByRole("button", { name: /close road detail panel/i, hidden: true })).not.toHaveFocus();

    rerender(panel({ isOpen: true }));
    expect(screen.getByRole("button", { name: /close road detail panel/i })).toHaveFocus();
  });

  it("does not steal focus back on re-renders with a new close handler", () => {
    const outside = document.createElement("button");
    outside.textContent = "outside";
    document.body.appendChild(outside);

    try {
      const { rerender } = render(panel({ onClose: vi.fn() }));
      outside.focus();
      expect(outside).toHaveFocus();

      // Simulates a map `moveend` re-render: same open state, fresh callbacks.
      rerender(panel({ onClose: vi.fn(), onClearSelection: vi.fn() }));
      rerender(panel({ onClose: vi.fn(), isLoading: true }));

      expect(outside).toHaveFocus();
    } finally {
      outside.remove();
    }
  });

  it("returns focus to the previously focused element when it closes", () => {
    const trigger = document.createElement("button");
    trigger.textContent = "trigger";
    document.body.appendChild(trigger);

    try {
      trigger.focus();
      const { rerender } = render(panel({ isOpen: true }));
      expect(screen.getByRole("button", { name: /close road detail panel/i })).toHaveFocus();

      rerender(panel({ isOpen: false }));
      expect(trigger).toHaveFocus();
    } finally {
      trigger.remove();
    }
  });
});

describe("segment drawer Escape handling", () => {
  it("closes on Escape using the latest close handler", () => {
    const firstClose = vi.fn();
    const latestClose = vi.fn();
    const { rerender } = render(panel({ onClose: firstClose }));
    rerender(panel({ onClose: latestClose }));

    fireEvent.keyDown(document, { key: "Escape" });

    expect(firstClose).not.toHaveBeenCalled();
    expect(latestClose).toHaveBeenCalledTimes(1);
  });

  it("ignores Escape events that were already handled", () => {
    const onClose = vi.fn();
    render(panel({ onClose }));

    const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    event.preventDefault();
    document.dispatchEvent(event);

    expect(onClose).not.toHaveBeenCalled();
  });

  it("ignores Escape pressed inside a dialog such as the feedback form", () => {
    const onClose = vi.fn();
    render(panel({ onClose }));

    const dialog = document.createElement("dialog");
    const textarea = document.createElement("textarea");
    dialog.appendChild(textarea);
    document.body.appendChild(dialog);

    try {
      fireEvent.keyDown(textarea, { key: "Escape" });
      expect(onClose).not.toHaveBeenCalled();
    } finally {
      dialog.remove();
    }
  });

  it("does not listen for Escape while closed", () => {
    const onClose = vi.fn();
    render(panel({ onClose, isOpen: false }));

    fireEvent.keyDown(document, { key: "Escape" });

    expect(onClose).not.toHaveBeenCalled();
  });
});
