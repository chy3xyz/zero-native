import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("migrating");

export default function MigratingLayout({ children }: { children: React.ReactNode }) {
  return children;
}
