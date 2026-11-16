// SD card browser (file_list listings) and downloads (file_chunk → data/file).
import {
  $,
  component$,
  useComputed$,
  useSignal,
  useStore,
} from "@builder.io/qwik";
import { errorText, query, stamp } from "./api";
import { bytes, fraction, percent } from "./format";
import { devicePath, send, useJson } from "./hooks";
import type { Device, FileDownload, FileListing } from "./types";
import { Feedback, LoadState, TableRegion } from "./widgets";

type Props = { device: Device; revision: number; operator: boolean };

export const joinPath = (dir: string, name: string) =>
  `${dir.replace(/\/+$/, "")}/${name.replace(/\/+$/, "")}`;
export const parentPath = (path: string) => {
  const parts = path.split("/").filter(Boolean);
  parts.pop();
  return `/${parts.join("/")}`;
};

export const FilesView = component$<Props>((props) => {
  const id = props.device.device_id;
  const path = useSignal("/GWL");
  const rev = useComputed$(() => props.revision);
  const listingsUrl = useComputed$(() =>
    devicePath(props.device.device_id, `/files?${query({ path: path.value })}`),
  );
  const downloadsUrl = useComputed$(() =>
    devicePath(props.device.device_id, "/files/downloads"),
  );
  const listings = useJson<{ listings: FileListing[] }>(listingsUrl, rev);
  const downloads = useJson<{ downloads: FileDownload[] }>(downloadsUrl, rev);
  const action = useStore({ pending: false, message: "", failed: false });
  const run = $(async (target: string, body: unknown, done: string) => {
    if (action.pending) return;
    action.pending = true;
    action.message = "";
    try {
      await send("POST", devicePath(id, target), body);
      action.message = done;
      action.failed = false;
      listings.reload();
      downloads.reload();
    } catch (error) {
      action.message = errorText(error);
      action.failed = true;
    } finally {
      action.pending = false;
    }
  });
  const pages = (listings.state.data?.listings || [])
    .filter((l) => l.path === path.value)
    .sort((a, b) => a.page - b.page);
  const entries = pages.flatMap((p) => p.files);
  const last = pages[pages.length - 1];
  const rows = downloads.state.data?.downloads || [];
  return (
    <>
      <section aria-labelledby="files-heading">
        <h2 id="files-heading">SD card</h2>
        <p class="muted">
          Listings and chunks travel as commands, so a sleeping logger answers
          at its next connection. Listings show what the logger last reported.
        </p>
        <form
          class="toolbar"
          preventdefault:submit
          onSubmit$={(_, form) => {
            const value = (
              form.elements.namedItem("sd-path") as HTMLInputElement
            ).value.trim();
            path.value = value.startsWith("/") ? value : `/${value}`;
          }}
        >
          <label class="field" for="sd-path">
            Directory
            <input id="sd-path" name="sd-path" value={path.value} />
          </label>
          <button type="submit">Show</button>
          {path.value !== "/" && (
            <button
              type="button"
              onClick$={() => {
                path.value = parentPath(path.value);
              }}
            >
              Up to {parentPath(path.value)}
            </button>
          )}
          {props.operator && (
            <button
              type="button"
              class="primary"
              disabled={action.pending}
              onClick$={() =>
                run(
                  "/files",
                  { path: path.value, page: 0 },
                  `Listing of ${path.value} requested (file_list). It appears after the logger answers.`,
                )
              }
            >
              Request listing
            </button>
          )}
        </form>
        <LoadState
          loading={listings.state.loading && !listings.state.data}
          error={listings.state.error}
          empty={pages.length === 0}
          emptyText={`No listing of ${path.value} has been received.`}
          label="listing"
        />
        {pages.length > 0 && (
          <>
            <p class="muted">
              {entries.length} entr{entries.length === 1 ? "y" : "ies"} on{" "}
              {pages.length} page
              {pages.length === 1 ? "" : "s"} · received{" "}
              {stamp(last.received_at)}
            </p>
            <TableRegion label={`Files in ${path.value}`}>
              <table>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Size</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map(([name, size]) => {
                    const dir = name.endsWith("/");
                    const full = joinPath(path.value, name);
                    return (
                      <tr key={name}>
                        <td class="mono">
                          {dir ? (
                            <button
                              type="button"
                              class="link-button"
                              onClick$={() => {
                                path.value = full;
                              }}
                            >
                              {name}
                            </button>
                          ) : (
                            name
                          )}
                        </td>
                        <td class="numeric">{dir ? "folder" : bytes(size)}</td>
                        <td>
                          {!dir && props.operator && (
                            <button
                              type="button"
                              disabled={action.pending}
                              onClick$={() =>
                                run(
                                  "/files/downloads",
                                  { path: full },
                                  `Download of ${full} started; chunks arrive while the logger is connected.`,
                                )
                              }
                            >
                              Download
                            </button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </TableRegion>
            {last.more && props.operator && (
              <button
                type="button"
                disabled={action.pending}
                onClick$={() =>
                  run(
                    "/files",
                    { path: path.value, page: last.page + 1 },
                    `Page ${last.page + 1} of ${path.value} requested.`,
                  )
                }
              >
                Request page {last.page + 1}
              </button>
            )}
          </>
        )}
        <Feedback message={action.message} failed={action.failed} />
      </section>
      <section aria-labelledby="downloads-heading">
        <h2 id="downloads-heading">Downloads</h2>
        <LoadState
          loading={downloads.state.loading && !downloads.state.data}
          error={downloads.state.error}
          empty={rows.length === 0}
          emptyText="No downloads yet."
          label="downloads"
        />
        {rows.length > 0 && (
          <TableRegion label="SD downloads">
            <table>
              <thead>
                <tr>
                  <th>File</th>
                  <th>Progress</th>
                  <th>State</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((d) => {
                  const done = fraction(d.received_bytes, d.size);
                  return (
                    <tr key={d.id}>
                      <td class="mono">
                        {d.path}
                        <small>
                          #{d.id} · {d.requested_by || ""} ·{" "}
                          {stamp(d.created_at)}
                        </small>
                      </td>
                      <td>
                        <progress
                          max={1}
                          value={done ?? 0}
                          aria-label={`Download ${d.id} progress`}
                        />
                        <small>
                          {bytes(d.received_bytes)} of {bytes(d.size)} (
                          {percent(done)})
                        </small>
                      </td>
                      <td>
                        <span
                          class={
                            d.state === "failed" ? "state error-text" : "state"
                          }
                        >
                          {d.state}
                        </span>
                        {d.crc32 && <small>CRC-32 {d.crc32}</small>}
                        {d.error && <small class="error-text">{d.error}</small>}
                        {d.current_command_id != null &&
                          d.state === "active" && (
                            <small>chunk command #{d.current_command_id}</small>
                          )}
                      </td>
                      <td>
                        {d.state === "complete" && (
                          <a
                            class="button"
                            href={devicePath(
                              id,
                              `/files/downloads/${d.id}/content`,
                            )}
                          >
                            Save file
                          </a>
                        )}
                        {["failed", "cancelled"].includes(d.state) &&
                          props.operator && (
                            <button
                              type="button"
                              disabled={action.pending}
                              onClick$={() =>
                                run(
                                  "/files/downloads",
                                  { path: d.path },
                                  `Download of ${d.path} started again; chunks arrive while the logger is connected.`,
                                )
                              }
                            >
                              Download again
                            </button>
                          )}
                        {d.state === "active" && props.operator && (
                          <button
                            type="button"
                            disabled={action.pending}
                            onClick$={() =>
                              run(
                                `/files/downloads/${d.id}/cancel`,
                                {},
                                `Download #${d.id} cancelled.`,
                              )
                            }
                          >
                            Cancel
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </TableRegion>
        )}
      </section>
    </>
  );
});
