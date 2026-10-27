import { render } from "@builder.io/qwik";
// CSR needs the delegated DOM listeners; rendering alone does not register them.
import "@builder.io/qwik/qwikloader.js";
import Root from "./root";
import "./styles.css";

const mount = document.getElementById("groundwater-app");
if (mount) void render(mount, <Root />);
