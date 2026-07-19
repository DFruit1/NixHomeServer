{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.files.archives;
  archiveViewPolicy = "extract-safe-single-root-v3";
  provenanceMarker = ".nixhomeserver-archive-view";
  safeDirectoryNameType = lib.types.strMatching "[A-Za-z0-9_][A-Za-z0-9._-]*";
  safeSuffixType = lib.types.strMatching "[.][A-Za-z0-9][A-Za-z0-9._-]*";
  safeIndexRootType =
    lib.types.strMatching "/persist/appdata(/[A-Za-z0-9][A-Za-z0-9._-]*)+";

  # The fileshare roots are intentionally writable by their users, while this
  # reconciler runs as root.  Keep every security-sensitive lookup relative to an
  # already-open directory descriptor so a user cannot swap a checked path for a
  # symlink (or another directory) before it is copied, published, or removed.
  archiveViewHelper = pkgs.writeTextFile {
    name = "files-archive-view-helper";
    destination = "/bin/files-archive-view-helper";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      import argparse
      import ctypes
      import hashlib
      import json
      import os
      import re
      import resource
      import secrets
      import signal
      import stat
      import subprocess
      import sys
      import time

      BSDTAR = "${pkgs.libarchive}/bin/bsdtar"
      MARKER = ${builtins.toJSON provenanceMarker}
      STAGE_MARKER = ".nixhomeserver-archive-stage"
      O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
      O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
      O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
      TOKEN = re.compile(r"^[0-9a-f]{64}$")


      class Refusal(RuntimeError):
          pass


      def refuse(message):
          raise Refusal(message)


      def identity(value):
          return (value.st_dev, value.st_ino)


      def signature(value):
          # Owner and mode are part of the signature, not merely size and mtime.
          return [
              value.st_dev,
              value.st_ino,
              value.st_size,
              value.st_mtime_ns,
              value.st_ctime_ns,
              value.st_uid,
              value.st_gid,
              stat.S_IMODE(value.st_mode),
          ]


      def normalize_beneath(root, candidate):
          root = os.path.abspath(root)
          candidate = os.path.abspath(candidate)
          try:
              beneath = os.path.commonpath((root, candidate)) == root
          except ValueError:
              beneath = False
          if not beneath or candidate == root:
              refuse("archive source is not beneath its allowed archive root")
          parts = os.path.relpath(candidate, root).split(os.sep)
          if not parts or any(part in ("", ".", "..") for part in parts):
              refuse("archive source contains an unsafe path component")
          return root, candidate, parts


      def open_parent(root, candidate):
          root, candidate, parts = normalize_beneath(root, candidate)
          root_fd = os.open(root, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          current_fd = root_fd
          try:
              if not stat.S_ISDIR(os.fstat(root_fd).st_mode):
                  refuse("allowed archive root is not a directory")
              for part in parts[:-1]:
                  next_fd = os.open(
                      part,
                      os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                      dir_fd=current_fd,
                  )
                  if current_fd != root_fd:
                      os.close(current_fd)
                  current_fd = next_fd
              return os.dup(current_fd), parts[-1], candidate
          finally:
              if current_fd != root_fd:
                  os.close(current_fd)
              os.close(root_fd)


      def open_source(root, source):
          parent_fd, name, source = open_parent(root, source)
          try:
              source_fd = os.open(
                  name,
                  os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
                  dir_fd=parent_fd,
              )
          except Exception:
              os.close(parent_fd)
              raise
          value = os.fstat(source_fd)
          if not stat.S_ISREG(value.st_mode) or value.st_nlink < 1:
              os.close(source_fd)
              os.close(parent_fd)
              refuse("archive source is not a regular file")
          return parent_fd, name, source_fd, value, source


      def exists_at(parent_fd, name):
          try:
              os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
              return True
          except FileNotFoundError:
              return False


      def same_open_path(parent_fd, name, opened_fd):
          try:
              return identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) == identity(
                  os.fstat(opened_fd)
              )
          except FileNotFoundError:
              return False


      def read_small_at(parent_fd, name):
          descriptor = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=parent_fd)
          try:
              value = os.fstat(descriptor)
              if (
                  not stat.S_ISREG(value.st_mode)
                  or value.st_uid != 0
                  or value.st_nlink != 1
                  or value.st_size > 8192
              ):
                  refuse("provenance is not a small root-owned regular file")
              data = os.read(descriptor, 8193)
              if len(data) > 8192:
                  refuse("provenance marker is too large")
              return data
          finally:
              os.close(descriptor)


      def write_at(parent_fd, name, data, mode):
          descriptor = os.open(
              name,
              os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              mode,
              dir_fd=parent_fd,
          )
          try:
              offset = 0
              while offset < len(data):
                  offset += os.write(descriptor, data[offset:])
              os.fsync(descriptor)
              os.fchmod(descriptor, mode)
              value = os.fstat(descriptor)
              if not stat.S_ISREG(value.st_mode) or value.st_uid != 0 or value.st_nlink != 1:
                  refuse("new provenance is not a root-owned regular file")
          finally:
              os.close(descriptor)


      def marker_data(policy, archive_hash, token, kind):
          return (
              json.dumps(
                  {
                      "archiveHash": archive_hash,
                      "kind": kind,
                      "policy": policy,
                      "token": token,
                  },
                  sort_keys=True,
                  separators=(",", ":"),
              ).encode()
              + b"\n"
          )


      def verify_marker(data, policy, archive_hash, kind):
          try:
              value = json.loads(data.decode())
          except (UnicodeDecodeError, json.JSONDecodeError) as error:
              raise Refusal("invalid archive-view provenance") from error
          if set(value) != {"archiveHash", "kind", "policy", "token"}:
              refuse("invalid archive-view provenance fields")
          if value["archiveHash"] != archive_hash or value["policy"] != policy:
              refuse("archive-view provenance belongs to another source")
          if value["kind"] != kind or not isinstance(value["token"], str):
              refuse("invalid archive-view provenance kind")
          if not TOKEN.fullmatch(value["token"]):
              refuse("invalid archive-view provenance token")
          return value


      def verify_directory(parent_fd, name, policy, archive_hash, kind="view"):
          descriptor = os.open(
              name,
              os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
              dir_fd=parent_fd,
          )
          try:
              value = os.fstat(descriptor)
              if not stat.S_ISDIR(value.st_mode) or value.st_uid != 0:
                  refuse("managed archive directory is not root-owned")
              marker = MARKER if kind == "view" else STAGE_MARKER
              try:
                  marker_contents = read_small_at(descriptor, marker)
              except FileNotFoundError as error:
                  raise Refusal("managed archive directory has no provenance marker") from error
              verify_marker(marker_contents, policy, archive_hash, kind)
              return descriptor, value
          except Exception:
              os.close(descriptor)
              raise


      def remove_contents(directory_fd):
          # Never follow a link and re-check every inode immediately before unlink.
          for name in os.listdir(directory_fd):
              try:
                  before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
              except FileNotFoundError:
                  continue
              if stat.S_ISDIR(before.st_mode):
                  try:
                      child_fd = os.open(
                          name,
                          os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                          dir_fd=directory_fd,
                      )
                  except (FileNotFoundError, NotADirectoryError):
                      continue
                  try:
                      if identity(os.fstat(child_fd)) != identity(before):
                          continue
                      remove_contents(child_fd)
                      if same_open_path(directory_fd, name, child_fd):
                          try:
                              os.rmdir(name, dir_fd=directory_fd)
                          except (FileNotFoundError, OSError):
                              pass
                  finally:
                      os.close(child_fd)
              else:
                  try:
                      current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                      if identity(current) == identity(before):
                          os.unlink(name, dir_fd=directory_fd)
                  except FileNotFoundError:
                      pass


      def remove_verified(parent_fd, name, directory_fd):
          remove_contents(directory_fd)
          if same_open_path(parent_fd, name, directory_fd):
              try:
                  os.rmdir(name, dir_fd=parent_fd)
              except (FileNotFoundError, OSError):
                  pass


      def create_stage(parent_fd, policy, archive_hash):
          token = secrets.token_hex(32)
          for _attempt in range(128):
              name = ".nixhomeserver-archive-stage-" + secrets.token_hex(16)
              try:
                  os.mkdir(name, 0o700, dir_fd=parent_fd)
                  break
              except FileExistsError:
                  continue
          else:
              refuse("could not allocate an unpredictable staging directory")
          descriptor = os.open(
              name,
              os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
              dir_fd=parent_fd,
          )
          value = os.fstat(descriptor)
          if not stat.S_ISDIR(value.st_mode) or value.st_uid != 0:
              os.close(descriptor)
              refuse("staging directory is not root-owned")
          os.fchmod(descriptor, 0o700)
          write_at(
              descriptor,
              STAGE_MARKER,
              marker_data(policy, archive_hash, token, "stage"),
              0o400,
          )
          return name, descriptor


      def cleanup_stage(parent_fd, name, stage_fd, policy, archive_hash):
          try:
              verified_fd, verified = verify_directory(parent_fd, name, policy, archive_hash, "stage")
          except (FileNotFoundError, NotADirectoryError, Refusal):
              return
          try:
              if identity(verified) == identity(os.fstat(stage_fd)):
                  remove_verified(parent_fd, name, verified_fd)
          finally:
              os.close(verified_fd)


      def stage_source(source_fd, before, stage_fd, maximum):
          if before.st_size > maximum:
              refuse("archive exceeds the configured compressed-size limit")
          staged_fd = os.open(
              "source.archive",
              os.O_RDWR | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              0o600,
              dir_fd=stage_fd,
          )
          digest = hashlib.sha256()
          total = 0
          try:
              while True:
                  chunk = os.read(source_fd, 1024 * 1024)
                  if not chunk:
                      break
                  total += len(chunk)
                  if total > maximum:
                      refuse("archive grew beyond the compressed-size limit while staging")
                  digest.update(chunk)
                  offset = 0
                  while offset < len(chunk):
                      offset += os.write(staged_fd, chunk[offset:])
              os.fsync(staged_fd)
              os.lseek(staged_fd, 0, os.SEEK_SET)
              if signature(os.fstat(source_fd)) != signature(before):
                  refuse("archive source changed while it was copied into staging")
              staged = os.fstat(staged_fd)
              if (
                  not stat.S_ISREG(staged.st_mode)
                  or staged.st_uid != 0
                  or staged.st_nlink != 1
                  or staged.st_size != total
              ):
                  refuse("staged archive is not a root-owned regular file")
              return staged_fd, digest.hexdigest()
          except Exception:
              os.close(staged_fd)
              raise


      def process_limits(maximum_file_size):
          def apply():
              resource.setrlimit(resource.RLIMIT_FSIZE, (maximum_file_size, maximum_file_size))
              resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
              os.umask(0o077)

          return apply


      def list_archive(staged_fd, stage_fd, name, verbose, timeout, output_limit):
          output_fd = os.open(
              name,
              os.O_RDWR | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              0o600,
              dir_fd=stage_fd,
          )
          command = [BSDTAR, "--list", "--file", "/proc/self/fd/" + str(staged_fd)]
          if verbose:
              command.insert(2, "--verbose")
          try:
              with os.fdopen(os.dup(output_fd), "wb") as output:
                  try:
                      result = subprocess.run(
                          command,
                          stdin=subprocess.DEVNULL,
                          stdout=output,
                          stderr=subprocess.DEVNULL,
                          pass_fds=(staged_fd,),
                          timeout=timeout,
                          check=False,
                          preexec_fn=process_limits(output_limit),
                      )
                  except subprocess.TimeoutExpired as error:
                      raise Refusal("archive metadata listing timed out") from error
              if result.returncode != 0:
                  refuse("unable to list archive safely")
              os.lseek(output_fd, 0, os.SEEK_SET)
              return output_fd
          except Exception:
              os.close(output_fd)
              raise


      def read_lines(descriptor, maximum_entries):
          os.lseek(descriptor, 0, os.SEEK_SET)
          lines = []
          with os.fdopen(os.dup(descriptor), "rb") as stream:
              while True:
                  line = stream.readline(1024 * 1024 + 1)
                  if not line:
                      break
                  if len(line) > 1024 * 1024 or not line.endswith(b"\n"):
                      refuse("archive member name is too long or malformed")
                  lines.append(line[:-1])
                  if len(lines) > maximum_entries:
                      refuse("archive exceeds the configured entry-count limit")
          return lines


      def validate_members(lines):
          common_root = None
          for raw in lines:
              entry = raw.decode("utf-8", "surrogateescape")
              while entry.startswith("./"):
                  entry = entry[2:]
              if not entry:
                  continue
              is_directory = entry.endswith("/")
              normalized = entry[:-1] if is_directory else entry
              parts = normalized.split("/")
              if entry.startswith("/") or any(part == ".." for part in parts):
                  refuse("Refusing unsafe archive member path: " + entry)
              if any(part in ("", ".") for part in parts):
                  refuse("Refusing ambiguous archive member path: " + entry)
              if len(parts) > 128:
                  refuse("archive member path exceeds the safe directory-depth limit")
              first = parts[0]
              if common_root is None:
                  common_root = first
              elif common_root != first:
                  common_root = ""
              if len(parts) == 1 and not is_directory:
                  common_root = ""
          return bool(common_root), common_root or ""


      def enforce_declared_size(lines, maximum):
          total = 0
          for raw in lines:
              fields = raw.decode("utf-8", "replace").split(maxsplit=8)
              if len(fields) < 6 or not fields[4].isdigit():
                  refuse("could not determine declared archive member sizes")
              total += int(fields[4])
              if total > maximum:
                  refuse("archive declares more expanded data than the configured limit")


      def tree_size(directory_fd):
          total = 0
          for name in os.listdir(directory_fd):
              try:
                  value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
              except FileNotFoundError:
                  continue
              if stat.S_ISREG(value.st_mode):
                  total += value.st_size
              elif stat.S_ISDIR(value.st_mode):
                  try:
                      child_fd = os.open(
                          name,
                          os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                          dir_fd=directory_fd,
                      )
                  except (FileNotFoundError, NotADirectoryError):
                      continue
                  try:
                      total += tree_size(child_fd)
                  finally:
                      os.close(child_fd)
          return total


      def terminate(process):
          if process.poll() is not None:
              return
          try:
              os.killpg(process.pid, signal.SIGTERM)
          except ProcessLookupError:
              return
          try:
              process.wait(timeout=5)
          except subprocess.TimeoutExpired:
              try:
                  os.killpg(process.pid, signal.SIGKILL)
              except ProcessLookupError:
                  pass
              process.wait()


      def extract(staged_fd, stage_fd, strip_root, maximum, timeout):
          os.mkdir("view", 0o700, dir_fd=stage_fd)
          view_fd = os.open(
              "view",
              os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
              dir_fd=stage_fd,
          )
          command = [
              BSDTAR,
              "--extract",
              "--file",
              "/proc/self/fd/" + str(staged_fd),
              "--directory",
              "/proc/self/fd/" + str(view_fd),
              "--no-same-owner",
              "--no-same-permissions",
          ]
          if strip_root:
              command.extend(("--strip-components", "1"))
          process = subprocess.Popen(
              command,
              stdin=subprocess.DEVNULL,
              stdout=subprocess.DEVNULL,
              stderr=subprocess.DEVNULL,
              pass_fds=(staged_fd, view_fd),
              start_new_session=True,
              preexec_fn=process_limits(maximum),
          )
          started = time.monotonic()
          try:
              while process.poll() is None:
                  # The declared-size preflight prevents normal overshoot.  This
                  # 50ms guard also catches malformed formats whose sizes lie.
                  if tree_size(view_fd) > maximum:
                      terminate(process)
                      refuse("archive expanded beyond the configured size limit")
                  if time.monotonic() - started > timeout:
                      terminate(process)
                      refuse("archive extraction timed out")
                  time.sleep(0.05)
              if process.returncode != 0:
                  refuse("archive extraction failed safely")
              if tree_size(view_fd) > maximum:
                  refuse("archive expanded beyond the configured size limit")
              return view_fd
          except Exception:
              terminate(process)
              os.close(view_fd)
              raise


      def sanitize(directory_fd):
          total = 0
          for name in os.listdir(directory_fd):
              value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
              if stat.S_ISLNK(value.st_mode):
                  # This is the descriptor-safe equivalent of:
                  # find "$tmp_path" -type l -delete
                  os.unlink(name, dir_fd=directory_fd)
              elif stat.S_ISDIR(value.st_mode):
                  child_fd = os.open(
                      name,
                      os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                      dir_fd=directory_fd,
                  )
                  try:
                      total += sanitize(child_fd)
                      os.fchmod(child_fd, 0o555)
                  finally:
                      os.close(child_fd)
              elif stat.S_ISREG(value.st_mode):
                  total += value.st_size
                  child_fd = os.open(name, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=directory_fd)
                  try:
                      child = os.fstat(child_fd)
                      os.fchmod(child_fd, 0o555 if child.st_mode & 0o111 else 0o444)
                  finally:
                      os.close(child_fd)
              else:
                  refuse("archive contains a device, FIFO, socket, or special member")
          return total


      def rename_noreplace(source_fd, source, destination_fd, destination):
          libc = ctypes.CDLL(None, use_errno=True)
          operation = getattr(libc, "renameat2", None)
          if operation is None:
              refuse("renameat2 is unavailable; refusing non-atomic publication")
          operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
          operation.restype = ctypes.c_int
          if operation(
              source_fd,
              os.fsencode(source),
              destination_fd,
              os.fsencode(destination),
              1,
          ) != 0:
              error = ctypes.get_errno()
              raise OSError(error, os.strerror(error), destination)


      def publish(stage_fd, staged_view_fd, parent_fd, view_name, policy, archive_hash):
          staged_identity = identity(os.fstat(staged_view_fd))
          retired_name = None
          retired_fd = None
          if exists_at(parent_fd, view_name):
              try:
                  existing_fd, existing = verify_directory(
                      parent_fd, view_name, policy, archive_hash
                  )
              except (OSError, Refusal) as error:
                  raise Refusal(
                      "refusing to replace a pre-existing view without valid root-owned provenance"
                  ) from error
              retired_name = ".nixhomeserver-archive-retired-" + secrets.token_hex(16)
              os.rename(view_name, retired_name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
              try:
                  retired_fd, retired = verify_directory(
                      parent_fd, retired_name, policy, archive_hash
                  )
                  if identity(existing) != identity(retired) or identity(os.fstat(existing_fd)) != identity(retired):
                      refuse("archive view changed during retirement; preserving it")
              except Exception:
                  if not exists_at(parent_fd, view_name):
                      try:
                          rename_noreplace(parent_fd, retired_name, parent_fd, view_name)
                      except OSError:
                          pass
                  raise
              finally:
                  os.close(existing_fd)
          try:
              rename_noreplace(stage_fd, "view", parent_fd, view_name)
              published_fd, published = verify_directory(parent_fd, view_name, policy, archive_hash)
              try:
                  if identity(published) != staged_identity:
                      refuse("published view is not the verified staging directory")
              finally:
                  os.close(published_fd)
          except Exception:
              if retired_name and not exists_at(parent_fd, view_name):
                  try:
                      rename_noreplace(parent_fd, retired_name, parent_fd, view_name)
                  except OSError:
                      pass
              raise
          if retired_name and retired_fd is not None:
              try:
                  remove_verified(parent_fd, retired_name, retired_fd)
              finally:
                  os.close(retired_fd)


      def load_state(path):
          try:
              descriptor = os.open(path, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
          except FileNotFoundError:
              return None
          try:
              value = os.fstat(descriptor)
              if (
                  not stat.S_ISREG(value.st_mode)
                  or value.st_uid != 0
                  or value.st_nlink != 1
                  or value.st_size > 16384
              ):
                  refuse("archive state is not a small root-owned regular file")
              return json.loads(os.read(descriptor, 16385).decode())
          except (UnicodeDecodeError, json.JSONDecodeError) as error:
              raise Refusal("archive state is invalid") from error
          finally:
              os.close(descriptor)


      def write_state(path, value):
          parent = os.path.dirname(path)
          name = os.path.basename(path)
          parent_fd = os.open(parent, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          temporary = "." + name + ".tmp-" + secrets.token_hex(16)
          try:
              write_at(
                  parent_fd,
                  temporary,
                  json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n",
                  0o600,
              )
              os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
              os.fsync(parent_fd)
          finally:
              try:
                  os.unlink(temporary, dir_fd=parent_fd)
              except FileNotFoundError:
                  pass
              os.close(parent_fd)


      def remove_state(path):
          try:
              descriptor = os.open(path, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
          except FileNotFoundError:
              return
          try:
              value = os.fstat(descriptor)
              if not stat.S_ISREG(value.st_mode) or value.st_uid != 0 or value.st_nlink != 1:
                  refuse("refusing to remove untrusted archive state")
              if identity(os.stat(path, follow_symlinks=False)) == identity(value):
                  os.unlink(path)
          finally:
              os.close(descriptor)


      def reconcile(args):
          parent_fd, source_name, source_fd, before, source = open_source(args.root, args.source)
          view_name = source_name + args.suffix
          if len(os.fsencode(view_name)) > 255:
              refuse("archive filename plus view suffix exceeds the filesystem name limit")
          stage_name = None
          stage_fd = None
          staged_fd = None
          view_fd = None
          existing_fd = None
          try:
              if exists_at(parent_fd, view_name):
                  try:
                      existing_fd, _existing = verify_directory(
                          parent_fd, view_name, args.policy, args.archive_hash
                      )
                  except (OSError, Refusal) as error:
                      raise Refusal("refusing to alter pre-existing path " + source + args.suffix) from error
              state = load_state(args.state)
              expected = {
                  "archiveHash": args.archive_hash,
                  "policy": args.policy,
                  "sha256": state.get("sha256") if isinstance(state, dict) else None,
                  "sourceSignature": signature(before),
              }
              if (
                  state == expected
                  and existing_fd is not None
                  and same_open_path(parent_fd, view_name, existing_fd)
              ):
                  print("Archive view is current: " + source + args.suffix)
                  return
              if existing_fd is not None:
                  os.close(existing_fd)
                  existing_fd = None
              stage_name, stage_fd = create_stage(parent_fd, args.policy, args.archive_hash)
              staged_fd, digest = stage_source(
                  source_fd, before, stage_fd, args.maximum_archive_bytes
              )
              output_limit = min(
                  256 * 1024 * 1024,
                  max(1024 * 1024, args.maximum_entries * 4096),
              )
              list_fd = list_archive(
                  staged_fd, stage_fd, "members.list", False, args.timeout_seconds, output_limit
              )
              try:
                  members = read_lines(list_fd, args.maximum_entries)
              finally:
                  os.close(list_fd)
              strip_root, common_root = validate_members(members)
              verbose_fd = list_archive(
                  staged_fd, stage_fd, "members.verbose", True, args.timeout_seconds, output_limit
              )
              try:
                  verbose = read_lines(verbose_fd, args.maximum_entries)
              finally:
                  os.close(verbose_fd)
              if len(verbose) != len(members):
                  refuse("archive metadata listings disagree on entry count")
              enforce_declared_size(verbose, args.maximum_expanded_bytes)
              if strip_root:
                  print("Extracting and stripping common root " + repr(common_root) + ": " + source)
              else:
                  print("Extracting without a common root: " + source)
              view_fd = extract(
                  staged_fd,
                  stage_fd,
                  strip_root,
                  args.maximum_expanded_bytes,
                  args.timeout_seconds,
              )
              expanded = sanitize(view_fd)
              if expanded > args.maximum_expanded_bytes:
                  refuse("archive expanded beyond the configured size limit")
              write_at(
                  view_fd,
                  MARKER,
                  marker_data(args.policy, args.archive_hash, secrets.token_hex(32), "view"),
                  0o444,
              )
              os.fchmod(view_fd, 0o555)
              publish(stage_fd, view_fd, parent_fd, view_name, args.policy, args.archive_hash)
              write_state(
                  args.state,
                  {
                      "archiveHash": args.archive_hash,
                      "policy": args.policy,
                      "sha256": digest,
                      "sourceSignature": signature(before),
                  },
              )
              print("Published managed archive view: " + source + args.suffix)
          finally:
              if existing_fd is not None:
                  os.close(existing_fd)
              if view_fd is not None:
                  os.close(view_fd)
              if staged_fd is not None:
                  os.close(staged_fd)
              if stage_fd is not None:
                  cleanup_stage(parent_fd, stage_name, stage_fd, args.policy, args.archive_hash)
                  os.close(stage_fd)
              os.close(source_fd)
              os.close(parent_fd)


      def remove_stale(args):
          parent_fd, source_name, _source = open_parent(args.root, args.source)
          view_name = source_name + args.suffix
          try:
              try:
                  view_fd, _view = verify_directory(
                      parent_fd, view_name, args.policy, args.archive_hash
                  )
              except FileNotFoundError:
                  return
              except (OSError, Refusal) as error:
                  raise Refusal(
                      "refusing stale cleanup without valid root-owned provenance: "
                      + args.source
                      + args.suffix
                  ) from error
              try:
                  remove_verified(parent_fd, view_name, view_fd)
                  if exists_at(parent_fd, view_name):
                      refuse("stale view changed during cleanup and was preserved")
              finally:
                  os.close(view_fd)
              remove_state(args.state)
              print("Removed proven stale archive view: " + args.source + args.suffix)
          finally:
              os.close(parent_fd)


      def positive(value):
          value = int(value)
          if value <= 0:
              raise argparse.ArgumentTypeError("value must be positive")
          return value


      def common(parser):
          parser.add_argument("--source", required=True)
          parser.add_argument("--root", required=True)
          parser.add_argument("--suffix", required=True)
          parser.add_argument("--state", required=True)
          parser.add_argument("--archive-hash", required=True)
          parser.add_argument("--policy", required=True)


      def arguments():
          parser = argparse.ArgumentParser()
          commands = parser.add_subparsers(dest="command", required=True)
          reconcile_parser = commands.add_parser("reconcile")
          common(reconcile_parser)
          reconcile_parser.add_argument("--maximum-archive-bytes", type=positive, required=True)
          reconcile_parser.add_argument("--maximum-expanded-bytes", type=positive, required=True)
          reconcile_parser.add_argument("--maximum-entries", type=positive, required=True)
          reconcile_parser.add_argument("--timeout-seconds", type=positive, required=True)
          remove_parser = commands.add_parser("remove")
          common(remove_parser)
          return parser.parse_args()


      def main():
          try:
              if os.geteuid() != 0:
                  refuse("archive reconciliation must run as root")
              args = arguments()
              if not args.suffix or "/" in args.suffix:
                  refuse("archive suffix must be a non-empty basename suffix")
              if not TOKEN.fullmatch(args.archive_hash):
                  refuse("archive hash must be a lowercase SHA-256 digest")
              if args.command == "reconcile":
                  reconcile(args)
              else:
                  remove_stale(args)
          except (Refusal, OSError) as error:
              print("Refusing unsafe archive operation: " + str(error), file=sys.stderr)
              return 1
          return 0


      if __name__ == "__main__":
          sys.exit(main())
    '';
  };

  syncArchivesScript = pkgs.writeShellScript "files-archives-sync" ''
    set -euo pipefail

    archive_dir=${builtins.toJSON cfg.directoryName}
    mount_suffix=${builtins.toJSON cfg.mountSuffix}
    archive_view_policy=${builtins.toJSON archiveViewPolicy}
    users_root=${builtins.toJSON vars.usersRoot}
    shared_root=${builtins.toJSON vars.sharedRoot}
    state_root=${builtins.toJSON cfg.indexRoot}
    supported_extensions_json=${lib.escapeShellArg (builtins.toJSON cfg.supportedExtensions)}
    maximum_archive_bytes=${toString cfg.maximumArchiveBytes}
    maximum_expanded_bytes=${toString cfg.maximumExpandedBytes}
    maximum_entries=${toString cfg.maximumEntries}
    extraction_timeout_seconds=${toString cfg.extractionTimeoutSeconds}
    archive_view_helper=${archiveViewHelper}/bin/files-archive-view-helper

    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$state_root"
    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$state_root/state"

    mapfile -t supported_extensions < <(
      ${pkgs.jq}/bin/jq -r '.[]' <<<"$supported_extensions_json"
    )

    declare -A desired_archives=()
    declare -A desired_roots=()

    archive_hash() {
      printf '%s' "$archive_view_policy:$1" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    }

    state_file_for_archive() {
      local archive_path="$1"
      printf '%s/state/%s.json\n' "$state_root" "$(archive_hash "$archive_path")"
    }

    is_supported_archive() {
      local path="$1"
      local lower_path="''${path,,}"
      local extension

      for extension in "''${supported_extensions[@]}"; do
        if [[ "$lower_path" == *"''${extension,,}" ]]; then
          return 0
        fi
      done

      return 1
    }

    archive_roots() {
      if [[ -d "$shared_root/$archive_dir" ]]; then
        printf '%s\0' "$shared_root/$archive_dir"
      fi

      if [[ -d "$users_root" ]]; then
        ${pkgs.findutils}/bin/find "$users_root" \
          -mindepth 2 \
          -maxdepth 2 \
          -type d \
          -name "$archive_dir" \
          -print0
      fi
    }

    scan_desired_archives() {
      local root
      local archive_path

      while IFS= read -r -d "" root; do
        while IFS= read -r -d "" archive_path; do
          if is_supported_archive "$archive_path"; then
            desired_archives["$archive_path"]=1
            desired_roots["$archive_path"]="$root"
          fi
        done < <(
          ${pkgs.findutils}/bin/find "$root" \
            -type d \
            -name '.nixhomeserver-archive-stage-*' \
            -prune \
            -o \
            -type d \
            -name "*$mount_suffix" \
            -prune \
            -o \
            -type f \
            -print0
        )
      done < <(archive_roots)
    }

    cleanup_stale_views() {
      local root
      local view_path
      local archive_path
      local failure=0

      while IFS= read -r -d "" root; do
        while IFS= read -r -d "" view_path; do
          archive_path="''${view_path%$mount_suffix}"
          if [[ -e "$archive_path" ]]; then
            continue
          fi
          if ! "$archive_view_helper" remove \
            --source "$archive_path" \
            --root "$root" \
            --suffix "$mount_suffix" \
            --state "$(state_file_for_archive "$archive_path")" \
            --archive-hash "$(archive_hash "$archive_path")" \
            --policy "$archive_view_policy"; then
            failure=1
          fi
        done < <(
          ${pkgs.findutils}/bin/find "$root" \
            -type d \
            -name "*$mount_suffix" \
            -prune \
          -print0
        )
      done < <(archive_roots)

      return "$failure"
    }

    reconcile_desired_views() {
      local archive_path
      local state_file
      local failure=0

      for archive_path in "''${!desired_archives[@]}"; do
        state_file="$(state_file_for_archive "$archive_path")"
        if ! "$archive_view_helper" reconcile \
          --source "$archive_path" \
          --root "''${desired_roots[$archive_path]}" \
          --suffix "$mount_suffix" \
          --state "$state_file" \
          --archive-hash "$(archive_hash "$archive_path")" \
          --policy "$archive_view_policy" \
          --maximum-archive-bytes "$maximum_archive_bytes" \
          --maximum-expanded-bytes "$maximum_expanded_bytes" \
          --maximum-entries "$maximum_entries" \
          --timeout-seconds "$extraction_timeout_seconds"; then
          failure=1
        fi
      done

      return "$failure"
    }

    scan_desired_archives
    failures=0
    cleanup_stale_views || failures=1
    reconcile_desired_views || failures=1
    exit "$failures"
  '';

  watcherScript = pkgs.writeShellScript "files-archives-watch" ''
    set -euo pipefail

    archive_dir=${builtins.toJSON cfg.directoryName}
    users_root=${builtins.toJSON vars.usersRoot}
    shared_root=${builtins.toJSON vars.sharedRoot}
    trigger_unit=files-archives-sync.service
    settle_seconds=${toString cfg.settleSeconds}
    poll_seconds=${toString cfg.pollSeconds}
    events=CLOSE_WRITE,CREATE,MOVED_TO,MOVED_FROM,DELETE,DELETE_SELF,ATTRIB

    declare -a watch_roots=()
    watcher_pid=""

    cleanup_watcher() {
      if [[ -n "$watcher_pid" ]]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
      fi
      watcher_pid=""
    }

    trap cleanup_watcher EXIT

    collect_watch_roots() {
      watch_roots=()

      if [[ -d "$shared_root/$archive_dir" ]]; then
        watch_roots+=("$shared_root/$archive_dir")
      fi

      if [[ -d "$users_root" ]]; then
        while IFS= read -r -d "" root; do
          watch_roots+=("$root")
        done < <(
          ${pkgs.findutils}/bin/find "$users_root" \
            -mindepth 2 \
            -maxdepth 2 \
            -type d \
            -name "$archive_dir" \
            -print0 \
            | ${pkgs.coreutils}/bin/sort -z
        )
      fi
    }

    watch_roots_key() {
      printf '%s\0' "''${watch_roots[@]}" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    }

    trigger_sync() {
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$trigger_unit"; then
        return 1
      fi

      echo "starting $trigger_unit after settled archive changes"
      ${pkgs.systemd}/bin/systemctl start "$trigger_unit"
    }

    while true; do
      collect_watch_roots
      if (( ''${#watch_roots[@]} == 0 )); then
        sleep "$poll_seconds"
        continue
      fi

      roots_key="$(watch_roots_key)"
      coproc WATCHER {
        exec ${pkgs.inotify-tools}/bin/inotifywait \
          --monitor \
          --quiet \
          --recursive \
          --format '%w%f|%e' \
          --event "$events" \
          "''${watch_roots[@]}"
      }
      watcher_pid="$WATCHER_PID"

      dirty=0
      last_change=0

      while true; do
        if IFS= read -r -t "$poll_seconds" event <&''${WATCHER[0]}; then
          dirty=1
          last_change="$(${pkgs.coreutils}/bin/date +%s)"
          continue
        fi

        if ! kill -0 "$watcher_pid" 2>/dev/null; then
          wait "$watcher_pid" || true
          watcher_pid=""
          echo "archive inotify watcher exited; refreshing watch roots" >&2
          break
        fi

        collect_watch_roots
        if [[ "$(watch_roots_key)" != "$roots_key" ]]; then
          cleanup_watcher
          break
        fi

        if (( dirty == 0 )); then
          continue
        fi

        now="$(${pkgs.coreutils}/bin/date +%s)"
        if (( now - last_change < settle_seconds )); then
          continue
        fi

        if trigger_sync; then
          dirty=0
        fi
      done
    done
  '';
in
{
  options.repo.files.archives = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable browsable archive views for the Files service.";
    };

    directoryName = lib.mkOption {
      type = safeDirectoryNameType;
      default = "_Archives";
      description = "Directory under each fileshare root where archive files are exposed as browsable views.";
    };

    mountSuffix = lib.mkOption {
      type = safeSuffixType;
      default = ".contents";
      description = "Suffix appended to an archive filename for its extracted read-only view directory.";
    };

    supportedExtensions = lib.mkOption {
      type = lib.types.listOf safeSuffixType;
      default = [
        ".zip"
        ".tar"
        ".tar.gz"
        ".tgz"
        ".tar.xz"
        ".txz"
        ".tar.zst"
        ".tzst"
        ".tar.bz2"
        ".tbz2"
        ".7z"
        ".rar"
      ];
      description = "Case-insensitive archive extensions that should receive extracted views.";
    };

    indexRoot = lib.mkOption {
      type = safeIndexRootType;
      default = "/persist/appdata/files-archives";
      description = "Persistent root for archive view source state.";
    };

    settleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Seconds without matching archive changes before the watcher starts a sync.";
    };

    pollSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Seconds between archive watcher health polls.";
    };

    maximumArchiveBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10 * 1024 * 1024 * 1024;
      description = "Maximum compressed archive size accepted for an extracted view.";
    };

    maximumExpandedBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20 * 1024 * 1024 * 1024;
      description = "Maximum disk space an extracted archive view may consume.";
    };

    maximumEntries = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100000;
      description = "Maximum number of archive entries accepted for an extracted view.";
    };

    extractionTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Maximum wall-clock time for extracting one archive.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.stringLength cfg.directoryName <= 128;
        message = "repo.files.archives.directoryName must not exceed 128 characters.";
      }
      {
        assertion = builtins.stringLength cfg.mountSuffix <= 64;
        message = "repo.files.archives.mountSuffix must not exceed 64 characters.";
      }
      {
        assertion =
          cfg.supportedExtensions != [ ]
          && builtins.length (lib.unique (map lib.toLower cfg.supportedExtensions))
          == builtins.length cfg.supportedExtensions
          && lib.all (extension: builtins.stringLength extension <= 32) cfg.supportedExtensions;
        message = "repo.files.archives.supportedExtensions must be non-empty, case-insensitively unique, safe suffixes of at most 32 characters.";
      }
      {
        assertion = lib.hasPrefix "/persist/appdata/" cfg.indexRoot;
        message = "repo.files.archives.indexRoot must remain below /persist/appdata.";
      }
      {
        assertion = cfg.settleSeconds > 0 && cfg.pollSeconds > 0 && cfg.extractionTimeoutSeconds > 0;
        message = "repo.files.archives watcher and extraction intervals must be positive.";
      }
    ];

    environment.systemPackages = [
      pkgs.libarchive
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.indexRoot} 0750 root root -"
      "d ${cfg.indexRoot}/state 0750 root root -"
    ];

    systemd.services.files-archives-sync = {
      description = "Reconcile extracted views for Files archive directories";
      restartIfChanged = false;
      environment = {
        ARCHIVE_VIEW_HELPER = "${archiveViewHelper}/bin/files-archive-view-helper";
      };
      requires = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
      ];
      after = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        MemoryHigh = "768M";
        MemoryMax = "1G";
        TasksMax = 128;
        RuntimeMaxSec = "2h";
        LimitFSIZE = toString cfg.maximumExpandedBytes;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = [
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
          "CAP_FOWNER"
        ];
        ReadWritePaths = [
          vars.usersRoot
          vars.sharedRoot
          cfg.indexRoot
        ];
      };
      unitConfig = lib.mkMerge [
        { RequiresMountsFor = [ vars.dataRoot ]; }
        (lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        })
      ];
      path = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.jq
      ];
      script = ''
        ${syncArchivesScript}
      '';
    };

    systemd.timers.files-archives-sync = {
      description = "Schedule archive view reconciliation after boot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5min";
        Unit = "files-archives-sync.service";
      };
    };

    systemd.services.files-archives-watch = {
      description = "Watch Files archive directories and debounce archive view reconciliation";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
      ];
      after = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${watcherScript}";
        Restart = "always";
        RestartSec = "5s";
      };
      unitConfig = lib.mkMerge [
        { RequiresMountsFor = [ vars.dataRoot ]; }
        (lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        })
      ];
    };
  };
}
