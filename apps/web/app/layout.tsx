import type { Metadata } from "next";
import { Fraunces, Manrope } from "next/font/google";

import "mapbox-gl/dist/mapbox-gl.css";
import "./globals.css";

const serif = Fraunces({
  variable: "--font-serif",
  subsets: ["latin"],
});

const sans = Manrope({
  variable: "--font-sans",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "RoadSense NS",
  description: "Public road-quality, pothole, and coverage explorer for Nova Scotia.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${serif.variable} ${sans.variable}`}>
      <body>{children}</body>
    </html>
  );
}
