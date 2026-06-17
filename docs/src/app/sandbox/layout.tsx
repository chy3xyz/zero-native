import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("sandbox");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
