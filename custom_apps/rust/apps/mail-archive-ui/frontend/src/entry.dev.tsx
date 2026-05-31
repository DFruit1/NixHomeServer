import { render } from "@builder.io/qwik";
import Root from "./root";
import "./styles.css";

const mount = document.getElementById("mail-archive-ui-islands");
if (mount) {
  render(mount, <Root />);
}
