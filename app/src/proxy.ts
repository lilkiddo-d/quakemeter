import { NextResponse, type NextRequest } from "next/server";

// Next.js 16 "proxy" (formerly middleware). Geoblocks by Vercel's x-vercel-ip-country header.
// NEXT_PUBLIC_GEOBLOCK_COUNTRIES is inlined at build time; empty = no geoblock.
const BLOCKED = new Set(
  (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES ?? "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter((s) => /^[A-Z]{2}$/.test(s)),
);

const ALWAYS_ALLOWED = ["/blocked", "/risk"];

export function proxy(request: NextRequest) {
  if (BLOCKED.size === 0) return NextResponse.next();
  const { pathname } = request.nextUrl;
  if (ALWAYS_ALLOWED.some((p) => pathname === p || pathname.startsWith(p + "/"))) return NextResponse.next();
  const country = (request.headers.get("x-vercel-ip-country") ?? "").toUpperCase();
  if (country && BLOCKED.has(country)) {
    const url = request.nextUrl.clone();
    url.pathname = "/blocked";
    url.search = "";
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|txt|xml)$).*)"],
};
