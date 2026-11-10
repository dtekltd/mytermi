"use client";

import { type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes } from "react";

export function cx(...c: (string | false | null | undefined)[]) {
  return c.filter(Boolean).join(" ");
}

export function Card({ title, actions, children, className }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={cx("rounded-2xl bg-surface p-5 shadow-sm ring-1 ring-line/60", className)}>
      {(title || actions) && (
        <div className="mb-4 flex items-center justify-between gap-3">
          {title && <h2 className="text-base font-semibold">{title}</h2>}
          {actions}
        </div>
      )}
      {children}
    </section>
  );
}

type BtnProps = ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "ghost" | "danger"; busy?: boolean };

export function Button({ variant = "primary", busy, className, children, disabled, ...rest }: BtnProps) {
  return (
    <button
      {...rest}
      disabled={disabled || busy}
      className={cx(
        "inline-flex items-center justify-center gap-2 rounded-xl px-4 py-2 text-sm font-medium transition disabled:opacity-50",
        variant === "primary" && "bg-accent text-white hover:bg-accent-strong",
        variant === "ghost" && "bg-surface-hi/60 text-fg hover:bg-surface-hi",
        variant === "danger" && "bg-red-600/10 text-red-600 hover:bg-red-600/20 dark:text-red-400",
        className,
      )}
    >
      {busy && <span className="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" />}
      {children}
    </button>
  );
}

export function Field({ label, hint, children }: { label: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-sm font-medium">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-xs text-dim">{hint}</span>}
    </label>
  );
}

const inputCls =
  "w-full rounded-xl border border-line bg-bg px-3 py-2 text-sm outline-none transition focus:border-accent focus:ring-2 focus:ring-accent/25";

export function Input(props: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...props} className={cx(inputCls, props.className)} />;
}

export function Select(props: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select {...props} className={cx(inputCls, "pr-8", props.className)} />;
}

export function Toggle({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: ReactNode }) {
  return (
    <label className="flex cursor-pointer items-center justify-between gap-4 py-1">
      <span className="text-sm">{label}</span>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        onClick={() => onChange(!checked)}
        className={cx("relative h-6 w-11 shrink-0 rounded-full transition", checked ? "bg-accent" : "bg-surface-hi")}
      >
        <span className={cx("absolute top-0.5 size-5 rounded-full bg-white shadow transition", checked ? "left-5.5" : "left-0.5")} />
      </button>
    </label>
  );
}

export function Badge({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "green" | "red" | "blue" | "amber" }) {
  return (
    <span
      className={cx(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        tone === "neutral" && "bg-surface-hi text-dim",
        tone === "green" && "bg-emerald-500/15 text-emerald-700 dark:text-emerald-300",
        tone === "red" && "bg-red-500/15 text-red-700 dark:text-red-300",
        tone === "blue" && "bg-sky-500/15 text-sky-700 dark:text-sky-300",
        tone === "amber" && "bg-amber-500/15 text-amber-700 dark:text-amber-300",
      )}
    >
      {children}
    </span>
  );
}

export function Alert({ children, tone = "red" }: { children: ReactNode; tone?: "red" | "green" | "amber" }) {
  return (
    <div
      className={cx(
        "rounded-xl px-4 py-3 text-sm",
        tone === "red" && "bg-red-500/10 text-red-700 dark:text-red-300",
        tone === "green" && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
        tone === "amber" && "bg-amber-500/10 text-amber-800 dark:text-amber-200",
      )}
    >
      {children}
    </div>
  );
}

export function Spinner() {
  return (
    <div className="flex justify-center py-16">
      <span className="size-6 animate-spin rounded-full border-2 border-accent border-t-transparent" />
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="py-10 text-center text-sm text-dim">{children}</p>;
}

export function PageTitle({ title, subtitle, actions }: { title: string; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-dim">{subtitle}</p>}
      </div>
      {actions}
    </div>
  );
}

const providerTone: Record<string, "blue" | "neutral" | "green" | "amber"> = {
  google: "blue",
  apple: "neutral",
  password: "green",
};

export function Providers({ list }: { list: string[] }) {
  if (!list.length) return <Badge tone="amber">email code</Badge>;
  return (
    <span className="flex flex-wrap gap-1">
      {list.map((p) => (
        <Badge key={p} tone={providerTone[p] ?? "neutral"}>
          {p}
        </Badge>
      ))}
    </span>
  );
}
