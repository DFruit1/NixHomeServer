import { render } from "@builder.io/qwik";
import Root, { initialRouteFromSearch } from "./root";
import "./styles.css";

const mount = document.getElementById("media-manager-app");
if (mount) {
  render(mount, <Root {...initialRouteFromSearch(window.location.search)} />);
}
