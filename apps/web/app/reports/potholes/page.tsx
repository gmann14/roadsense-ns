import { redirect } from "next/navigation";

export default function MostReportedPotholesPage() {
  redirect("/?mode=potholes");
}
