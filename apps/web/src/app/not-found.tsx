import Link from "next/link";
export default function NotFound() {
  return <><h1 className="text-xl font-semibold">Content not found</h1><Link href="/" className="underline">Return to library</Link></>;
}
