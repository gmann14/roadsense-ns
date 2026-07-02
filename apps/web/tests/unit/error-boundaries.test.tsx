import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import ErrorPage from "@/app/error";
import Loading from "@/app/loading";
import NotFound from "@/app/not-found";

afterEach(() => {
  cleanup();
});

describe("app/error.tsx", () => {
  it("renders on-brand messaging and calls reset when retried", () => {
    const reset = vi.fn();
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    render(<ErrorPage error={new Error("boom")} reset={reset} />);

    expect(screen.getByText(/the map hit a pothole/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /try again/i }));
    expect(reset).toHaveBeenCalledTimes(1);

    consoleErrorSpy.mockRestore();
  });

  it("logs the error for diagnostics without leaking internals into the page", () => {
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const error = new Error("secret stack detail");

    render(<ErrorPage error={error} reset={vi.fn()} />);

    expect(consoleErrorSpy).toHaveBeenCalledWith(expect.stringContaining("unhandled page error"), error);
    expect(screen.queryByText(/secret stack detail/i)).not.toBeInTheDocument();

    consoleErrorSpy.mockRestore();
  });
});

describe("app/not-found.tsx", () => {
  it("renders a recoverable 404 with a link back to the map", () => {
    render(<NotFound />);

    expect(screen.getByText(/isn't on the map/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /back to the map/i })).toHaveAttribute("href", "/");
  });
});

describe("app/loading.tsx", () => {
  it("renders an accessible loading status", () => {
    render(<Loading />);

    expect(screen.getByRole("status")).toHaveTextContent(/loading the map/i);
  });
});
