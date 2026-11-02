/**
 * Kervan answers only over Tailscale, where setup has turned this on (KERVAN_TAILNET_ONLY): traffic there is encrypted,
 * and on a home network it wouldn't be, the app's key included. The firewall says the same; this holds if it doesn't.
 */
export const tailnetOnly = (): boolean => Boolean(process.env.KERVAN_TAILNET_ONLY);

const withoutMapping = (address: string) => address.replace(/^::ffff:/i, "").toLowerCase();

const isLoopback = (address: string) => address === "::1" || address.startsWith("127.");

/** Tailscale's own ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48. */
export function isTailnetAddress(address: string): boolean {
  const plain = withoutMapping(address);
  if (plain.startsWith("fd7a:115c:a1e0:")) return true;
  const parts = plain.split(".").map(Number);
  return parts.length === 4 && parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
}

/** A connection is fine if it stays on this machine, or both its ends are on the tailnet. */
export function allowedConnection(remote: string | undefined, local: string | undefined): boolean {
  if (!remote || !local) return false;
  const [from, to] = [withoutMapping(remote), withoutMapping(local)];
  if (isLoopback(from) && isLoopback(to)) return true;
  return isTailnetAddress(from) && isTailnetAddress(to);
}
