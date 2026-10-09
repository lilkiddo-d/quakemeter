import Link from "next/link";

export default function NotFound() {
  return (
    <div className="mx-auto max-w-xl py-16 text-center">
      <h1 className="text-2xl font-bold">Page not found</h1>
      <p className="mt-3 text-sm text-muted">This page does not exist or is not enabled on this deployment.</p>
      <Link href="/" className="mt-6 inline-block text-accent2 underline">Back to dashboard</Link>
    </div>
  );
}
