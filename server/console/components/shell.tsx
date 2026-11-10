"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

import { api, ApiError, type User } from "@/lib/api";
import { cx, Spinner } from "./ui";

const AdminContext = createContext<User | null>(null);
export const useAdmin = () => useContext(AdminContext)!;

const nav = [
  { href: "/", label: "Tổng quan", icon: "M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6" },
  { href: "/users/", label: "Người dùng", icon: "M17 20h5v-2a3 3 0 00-5.36-1.86M17 20H7m10 0v-2c0-.66-.13-1.28-.36-1.86M7 20H2v-2a3 3 0 015.36-1.86M7 20v-2c0-.66.13-1.28.36-1.86m0 0a5 5 0 019.28 0M15 7a3 3 0 11-6 0 3 3 0 016 0z" },
  { href: "/plans/", label: "Gói dịch vụ", icon: "M9 12l2 2 4-4M7.84 4.7a3.42 3.42 0 001.95-.8 3.42 3.42 0 014.42 0 3.42 3.42 0 001.95.8 3.42 3.42 0 013.14 3.14c.07.73.35 1.42.8 1.95a3.42 3.42 0 010 4.42 3.42 3.42 0 00-.8 1.95 3.42 3.42 0 01-3.14 3.14 3.42 3.42 0 00-1.95.8 3.42 3.42 0 01-4.42 0 3.42 3.42 0 00-1.95-.8 3.42 3.42 0 01-3.14-3.14 3.42 3.42 0 00-.8-1.95 3.42 3.42 0 010-4.42 3.42 3.42 0 00.8-1.95A3.42 3.42 0 017.84 4.7z" },
  { href: "/settings/", label: "Cấu hình", icon: "M10.33 4.32c.43-1.76 2.93-1.76 3.35 0a1.72 1.72 0 002.57 1.06c1.54-.94 3.31.83 2.37 2.37a1.72 1.72 0 001.07 2.57c1.75.43 1.75 2.92 0 3.35a1.72 1.72 0 00-1.07 2.57c.94 1.54-.83 3.31-2.37 2.37a1.72 1.72 0 00-2.57 1.07c-.42 1.75-2.92 1.75-3.35 0a1.72 1.72 0 00-2.57-1.07c-1.54.94-3.31-.83-2.37-2.37a1.72 1.72 0 00-1.06-2.57c-1.76-.43-1.76-2.92 0-3.35a1.72 1.72 0 001.06-2.57c-.94-1.54.83-3.31 2.37-2.37.99.6 2.28.07 2.57-1.06zM15 12a3 3 0 11-6 0 3 3 0 016 0z" },
  { href: "/audit/", label: "Nhật ký", icon: "M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01" },
];

function Icon({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" className="size-5">
      <path d={d} />
    </svg>
  );
}

/** Checks the console session and renders the sidebar layout. */
export function Shell({ children }: { children: ReactNode }) {
  const router = useRouter();
  const path = usePathname();
  const [user, setUser] = useState<User | null>(null);
  const [menu, setMenu] = useState(false);

  useEffect(() => {
    api<{ user: User }>("/me")
      .then((r) => setUser(r.user))
      .catch((e) => {
        if (e instanceof ApiError && (e.status === 401 || e.status === 403)) router.replace("/login/");
      });
  }, [router]);

  useEffect(() => setMenu(false), [path]);

  if (!user) return <Spinner />;

  const logout = async () => {
    await api("/logout", { method: "POST" }).catch(() => {});
    router.replace("/login/");
  };
  const active = (href: string) => (href === "/" ? path === "/" : path.startsWith(href.replace(/\/$/, "")));

  return (
    <AdminContext.Provider value={user}>
      <div className="min-h-screen lg:flex">
        <aside
          className={cx(
            "fixed inset-y-0 left-0 z-30 w-64 border-r border-line bg-surface p-4 transition-transform lg:static lg:translate-x-0",
            menu ? "translate-x-0" : "-translate-x-full",
          )}
        >
          <div className="mb-8 flex items-center gap-2.5 px-2 pt-1">
            <div className="grid size-9 place-items-center rounded-xl bg-accent font-mono text-sm font-bold text-white">&gt;_</div>
            <div>
              <div className="font-semibold leading-tight">MyTermi</div>
              <div className="text-xs text-dim">Console</div>
            </div>
          </div>
          <nav className="space-y-1">
            {nav.map((n) => (
              <Link
                key={n.href}
                href={n.href}
                className={cx(
                  "flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition",
                  active(n.href) ? "bg-accent/12 text-accent" : "text-dim hover:bg-surface-hi/60 hover:text-fg",
                )}
              >
                <Icon d={n.icon} />
                {n.label}
              </Link>
            ))}
          </nav>
          <div className="absolute inset-x-4 bottom-4 rounded-xl bg-bg p-3">
            <div className="truncate text-sm font-medium">{user.email}</div>
            <button onClick={logout} className="mt-1 text-xs text-dim hover:text-red-500">
              Đăng xuất
            </button>
          </div>
        </aside>
        {menu && <div className="fixed inset-0 z-20 bg-black/40 lg:hidden" onClick={() => setMenu(false)} />}
        <div className="min-w-0 flex-1">
          <header className="sticky top-0 z-10 flex items-center gap-3 border-b border-line bg-bg/90 px-4 py-3 backdrop-blur lg:hidden">
            <button onClick={() => setMenu(true)} className="rounded-lg p-1.5 hover:bg-surface-hi" aria-label="Menu">
              <Icon d="M4 6h16M4 12h16M4 18h16" />
            </button>
            <span className="font-semibold">MyTermi Console</span>
          </header>
          <main className="mx-auto max-w-6xl p-4 sm:p-6 lg:p-8">{children}</main>
        </div>
      </div>
    </AdminContext.Provider>
  );
}
