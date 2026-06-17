import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("api/metadata");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
