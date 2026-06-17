import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("api/runtime");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
