import { render } from "@builder.io/qwik";
// The Qwik core never attaches DOM listeners itself: the qwikloader registers
// the global event delegation that makes every onClick$ handler work. Without
// this import the client-rendered app displays but ignores all interaction.
import "@builder.io/qwik/qwikloader.js";
import Root, { initialRouteFromSearch } from "./root";
// Bundled faces behind --font-sans and --font-serif. Browsers fetch only the
// subsets and styles a page actually uses.
import "@fontsource-variable/public-sans/wght.css";
import "@fontsource-variable/public-sans/wght-italic.css";
import "@fontsource-variable/gelasio/wght.css";
import "@fontsource-variable/gelasio/wght-italic.css";
import "./styles.css";
import "./images-view.css";
import "./conversions-view.css";

const mount = document.getElementById("media-manager-app");
if (mount) {
  render(mount, <Root {...initialRouteFromSearch(window.location.search)} />);
}
