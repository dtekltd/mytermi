"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Alert, Button, Field, Input } from "@/components/ui";
import { api, errorText } from "@/lib/api";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      await api("/login", { method: "POST", body: { email, password } });
      router.replace("/");
    } catch (err) {
      setError(errorText(err));
      setBusy(false);
    }
  };

  return (
    <div className="grid min-h-screen place-items-center p-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-5 rounded-2xl bg-surface p-7 shadow-sm ring-1 ring-line/60">
        <div className="flex items-center gap-3">
          <div className="grid size-11 place-items-center rounded-xl bg-accent font-mono font-bold text-white">&gt;_</div>
          <div>
            <h1 className="text-lg font-semibold">MyTermi Console</h1>
            <p className="text-sm text-dim">Admin sign-in</p>
          </div>
        </div>
        {error && <Alert>{error}</Alert>}
        <Field label="Email">
          <Input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} autoFocus />
        </Field>
        <Field label="Password">
          <Input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <Button type="submit" busy={busy} className="w-full">
          Sign in
        </Button>
        <p className="text-xs leading-relaxed text-dim">
          Create the first admin with <code className="font-mono">mytermi admin create --email … --password …</code> or the environment variables <code className="font-mono">MYTERMI_ADMIN_EMAIL</code> / <code className="font-mono">MYTERMI_ADMIN_PASSWORD</code>.
        </p>
      </form>
    </div>
  );
}
