import { render } from "@builder.io/qwik";
// The Qwik core never attaches DOM listeners itself: the qwikloader registers
// the global event delegation that makes every onClick$ handler work. Without
// this import the client-rendered app displays but ignores all interaction.
import "@builder.io/qwik/qwikloader.js";
import Root, { initialRouteFromSearch } from "./root";
import "./styles.css";

const mount = document.getElementById("media-manager-app");
if (mount) {
  render(mount, <Root {...initialRouteFromSearch(window.location.search)} />);
}
