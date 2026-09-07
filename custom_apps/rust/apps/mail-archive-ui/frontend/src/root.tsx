import { component$ } from "@builder.io/qwik";
import { DashboardStatusIsland } from "./islands/DashboardStatusIsland";
import { AttachmentSelectionIsland } from "./islands/AttachmentSelectionIsland";
import { MailListIsland } from "./islands/MailListIsland";
import { PrioritySelectIsland } from "./islands/PrioritySelectIsland";

export default component$(() => (
  <>
    <DashboardStatusIsland />
    <AttachmentSelectionIsland />
    <MailListIsland />
    <PrioritySelectIsland />
  </>
));
