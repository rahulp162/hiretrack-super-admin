import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import LoginForm from "./components/LoginForm";
import { COOKIE_NAME, verifyAdminJwt } from "@/lib/auth";

export default async function Home() {
  const cookieStore = await cookies();
  const token = cookieStore.get(COOKIE_NAME)?.value;

  if (token) {
    const payload = await verifyAdminJwt(token);
    if (payload) {
      redirect("/dashboard");
    }
  }

  return <LoginForm />;
}
