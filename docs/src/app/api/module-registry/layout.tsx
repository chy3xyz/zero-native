import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("api/module-registry");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
