import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("extensions/plugins/os");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
