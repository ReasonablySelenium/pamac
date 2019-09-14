/*
 *  pamac-vala
 *
 *  Copyright (C) 2014-2019 Guillaume Benoit <guillaume@manjaro.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a get of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace Pamac {
	public class Transaction: Object {
		enum Type {
			INSTALL = (1 << 0),
			REMOVE = (1 << 1),
			UPDATE = (1 << 2),
			BUILD = (1 << 3)
		}
		TransactionInterface transaction_interface;
		delegate void TransactionAction ();
		bool waiting;
		protected MainLoop loop;
		// run transaction data
		bool sysupgrading;
		GenericSet<string?> to_install;
		GenericSet<string?> to_remove;
		GenericSet<string?> to_load;
		GenericSet<string?> to_build;
		GenericSet<string?> temporary_ignorepkgs;
		#if ENABLE_SNAP
		HashTable<string, SnapPackage> snap_to_install;
		HashTable<string, SnapPackage> snap_to_remove;
		#endif
		// building data
		string aurdb_path;
		GenericSet<string?> already_checked_aur_dep;
		GenericSet<string?> aur_desc_list;
		Queue<string> to_build_queue;
		GenericSet<string?> aur_pkgs_to_install;
		bool building;
		Cancellable build_cancellable;
		// transaction options
		public Database database { get; construct set; }
		public bool clone_build_files { get; set; }

		public signal void emit_action (string action);
		public signal void emit_action_progress (string action, string status, double progress);
		public signal void emit_download_progress (string action, string status, double progress);
		public signal void emit_hook_progress (string action, string details, string status, double progress);
		public signal void emit_script_output (string message);
		public signal void emit_warning (string message);
		public signal void emit_error (string message, string[] details);
		public signal void start_waiting ();
		public signal void stop_waiting ();
		public signal void start_preparing ();
		public signal void stop_preparing ();
		public signal void start_downloading ();
		public signal void stop_downloading ();
		public signal void start_building ();
		public signal void stop_building ();
		public signal void important_details_outpout (bool must_show);

		public Transaction (Database database) {
			Object (database: database);
		}

		construct {
			if (Posix.geteuid () == 0) {
				// we are root
				transaction_interface = new TransactionInterfaceRoot (database.config);
			} else {
				// use dbus daemon
				transaction_interface = new TransactionInterfaceDaemon (database.config);
			}
			waiting = false;
			loop = new MainLoop ();
			// transaction options
			clone_build_files = true;
			// run transaction data
			sysupgrading = false;
			to_install = new GenericSet<string?> (str_hash, str_equal);
			to_remove = new GenericSet<string?> (str_hash, str_equal);
			to_load = new GenericSet<string?> (str_hash, str_equal);
			to_build = new GenericSet<string?> (str_hash, str_equal);
			temporary_ignorepkgs = new GenericSet<string?> (str_hash, str_equal);
			#if ENABLE_SNAP
			snap_to_install = new HashTable<string, SnapPackage> (str_hash, str_equal);
			snap_to_remove = new HashTable<string, SnapPackage> (str_hash, str_equal);
			#endif
			// building data
			aurdb_path = "/tmp/pamac/aur-%s".printf (Environment.get_user_name ());
			already_checked_aur_dep = new GenericSet<string?> (str_hash, str_equal);
			aur_desc_list = new GenericSet<string?> (str_hash, str_equal);
			aur_pkgs_to_install = new GenericSet<string?> (str_hash, str_equal);
			to_build_queue = new Queue<string> ();
			build_cancellable = new Cancellable ();
			building = false;
		}

		public void quit_daemon () {
			transaction_interface.quit_daemon ();
		}

		protected virtual bool ask_commit (TransactionSummary summary) {
			// no confirm
			return true;
		}

		protected virtual bool ask_edit_build_files (TransactionSummary summary) {
			// no edit
			return false;
		}

		protected virtual void edit_build_files (string[] pkgnames) {
			// do nothing
		}

		protected virtual bool ask_import_key (string pkgname, string key, string owner) {
			// no import
			return false;
		}

		protected async SList<string> get_build_files (string pkgname) {
			string pkgdir_name = Path.build_path ("/", database.config.aur_build_dir, pkgname);
			var files = new SList<string> ();
			// PKGBUILD
			files.append (Path.build_path ("/", pkgdir_name, "PKGBUILD"));
			var srcinfo = File.new_for_path (Path.build_path ("/", pkgdir_name, ".SRCINFO"));
			try {
				// read .SRCINFO
				var dis = new DataInputStream (yield srcinfo.read_async ());
				string line;
				while ((line = yield dis.read_line_async ()) != null) {
					if ("source = " in line) {
						string source = line.split (" = ", 2)[1];
						if (!("://" in source)) {
							string source_path = Path.build_path ("/", pkgdir_name, source);
							var source_file = File.new_for_path (source_path);
							if (source_file.query_exists ()) {
								files.append (source_path);
							}
						}
					} else if ("install = " in line) {
						string install = line.split (" = ", 2)[1];
						string install_path = Path.build_path ("/", pkgdir_name, install);
						var install_file = File.new_for_path (install_path);
						if (install_file.query_exists ()) {
							files.append (install_path);
						}
					}
				}
			} catch (GLib.Error e) {
				critical ("%s\n", e.message);
			}
			return (owned) files;
		}

		protected virtual string[] choose_optdeps (string pkgname, string[] optdeps) {
			// do not install optdeps
			return {};
		}

		protected virtual int choose_provider (string depend, string[] providers) {
			// choose first provider
			return 0;
		}

		ErrorInfos get_current_error () {
			return transaction_interface.get_current_error ();
		}

		public bool get_authorization () {
			return transaction_interface.get_authorization ();
		}

		public void generate_mirrors_list (string country) {
			string country_copy = country;
			emit_action (dgettext (null, "Refreshing mirrors list") + "...");
			important_details_outpout (false);
			transaction_interface.generate_mirrors_list_data.connect (on_generate_mirrors_list_data);
			transaction_interface.generate_mirrors_list (country_copy);
			transaction_interface.generate_mirrors_list_data.disconnect (on_generate_mirrors_list_data);
			database.refresh ();
		}

		void on_generate_mirrors_list_data (string line) {
			emit_script_output (line);
		}

		public void clean_cache () {
			HashTable<string, int64?> details = database.get_clean_cache_details ();
			var iter = HashTableIter<string, int64?> (details);
			var array = new GenericArray<string> (details.length);
			unowned string name;
			while (iter.next (out name, null)) {
				array.add (name);
			}
			bool success = transaction_interface.clean_cache (array.data);
			if (!success) {
				handle_error (get_current_error ());
			}
		}

		public void clean_build_files () {
			bool success = transaction_interface.clean_build_files (database.config.aur_build_dir);
			// recreate buildir here to have good permissions
			try {
				Process.spawn_command_line_sync ("mkdir -p %s".printf (database.config.aur_build_dir));
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
			if (!success) {
				handle_error (get_current_error ());
			}
		}

		public bool set_pkgreason (string pkgname, uint reason) {
			string pkgname_copy = pkgname;
			bool success = transaction_interface.set_pkgreason (pkgname_copy, reason);
			database.refresh ();
			return success;
		}

		public void download_updates () {
			transaction_interface.download_updates ();
		}

		void compute_aur_build_list () {
			// set building to allow cancellation
			building = true;
			build_cancellable.reset ();
			compute_aur_build_list_real.begin (() => {
				building = false;
				loop.quit ();
			});
			loop.run ();
		}

		async void compute_aur_build_list_real () {
			string tmp_path = "/tmp/pamac";
			var launcher = new SubprocessLauncher (SubprocessFlags.NONE);
			var file = GLib.File.new_for_path (tmp_path);
			if (!file.query_exists ()) {
				yield database.launch_subprocess (launcher, {"mkdir", "-p", tmp_path});
				yield database.launch_subprocess (launcher, {"chmod", "a+w", tmp_path});
			}
			yield database.launch_subprocess (launcher, {"mkdir", "-p", aurdb_path});
			aur_desc_list.remove_all ();
			already_checked_aur_dep.remove_all ();
			var to_build_array = new GenericArray<string> ();
			foreach (unowned string pkgname in to_build) {
				to_build_array.add (pkgname);
			}
			yield check_aur_dep_list (to_build_array.data);
			if (aur_desc_list.length > 0) {
				// create a fake aur db
				yield database.launch_subprocess (launcher, {"rm", "-f", "%s/aur.db".printf (tmp_path)});
				string[] cmds = {"bsdtar", "-cf", "%s/aur.db".printf (tmp_path), "-C", aurdb_path};
				foreach (unowned string name_version in aur_desc_list) {
					cmds += name_version;
				}
				yield database.launch_subprocess (launcher, cmds);
			}
		}

		async void check_aur_dep_list (string[] pkgnames) {
			var dep_to_check = new GenericArray<string> ();
			var aur_pkgs = new HashTable<string, AURPackage> (str_hash, str_equal);
			if (clone_build_files) {
				aur_pkgs = database.get_aur_pkgs (pkgnames);
			}
			foreach (unowned string pkgname in pkgnames) {
				if (build_cancellable.is_cancelled ()) {
					return;
				}
				if (already_checked_aur_dep.contains (pkgname)) {
					continue;
				}
				File? clone_dir;
				if (clone_build_files) {
					unowned AURPackage? aur_pkg = aur_pkgs.lookup (pkgname);
					if (aur_pkg == null) {
						// error
						continue;
					}
					// clone build files
					// use packagebase in case of split package
					emit_action (dgettext (null, "Cloning %s build files").printf (aur_pkg.packagebase) + "...");
					clone_dir = database.clone_build_files (aur_pkg.packagebase, false);
					if (clone_dir == null) {
						// error
						continue;
					}
					already_checked_aur_dep.add (aur_pkg.packagebase);
				} else {
					clone_dir = File.new_for_path (Path.build_path ("/", database.config.aur_build_dir, pkgname));
					if (!clone_dir.query_exists ()) {
						// didn't find the target
						// parse all builddir to be sure to find it
						var builddir = File.new_for_path (database.config.aur_build_dir);
						try {
							FileEnumerator enumerator = yield builddir.enumerate_children_async ("standard::*", FileQueryInfoFlags.NONE);
							FileInfo info;
							while ((info = enumerator.next_file (null)) != null) {
								unowned string filename = info.get_name ();
								if (!(filename in already_checked_aur_dep)) {
									dep_to_check.add (filename);
								}
							}
						} catch (GLib.Error e) {
							critical ("%s\n", e.message);
						}
						continue;
					}
					emit_action (dgettext (null, "Generating %s informations").printf (pkgname) + "...");
					if (!(database.regenerate_srcinfo (pkgname, build_cancellable))) {
						// error
						continue;
					}
				}
				if (build_cancellable.is_cancelled ()) {
					return;
				}
				emit_action (dgettext (null, "Checking %s dependencies").printf (pkgname) + "...");
				var srcinfo = clone_dir.get_child (".SRCINFO");
				try {
					// read .SRCINFO
					var dis = new DataInputStream (yield srcinfo.read_async ());
					string? line;
					string current_section = "";
					bool current_section_is_pkgbase = true;
					var version = new StringBuilder ("");
					string pkgbase = "";
					string desc = "";
					string arch = Posix.utsname ().machine;
					var pkgnames_found = new SList<string> ();
					var global_depends = new List<string> ();
					var global_checkdepends = new SList<string> ();
					var global_makedepends = new SList<string> ();
					var global_conflicts = new List<string> ();
					var global_provides = new List<string> ();
					var global_replaces = new List<string> ();
					var global_validpgpkeys = new SList<string> ();
					var pkgnames_table = new HashTable<string, AURPackage> (str_hash, str_equal);
					while ((line = yield dis.read_line_async ()) != null) {
						if ("pkgbase = " in line) {
							pkgbase = line.split (" = ", 2)[1];
						} else if ("pkgdesc = " in line) {
							desc = line.split (" = ", 2)[1];
							if (!current_section_is_pkgbase) {
								unowned AURPackage? aur_pkg = pkgnames_table.get (current_section);
								if (aur_pkg != null) {
									aur_pkg.desc = desc;
								}
							}
						} else if ("pkgver = " in line) {
							version.append (line.split (" = ", 2)[1]);
						} else if ("pkgrel = " in line) {
							version.append ("-");
							version.append (line.split (" = ", 2)[1]);
						} else if ("epoch = " in line) {
							version.prepend (":");
							version.prepend (line.split (" = ", 2)[1]);
						// don't compute optdepends, it will be done by makepkg
						} else if ("optdepends" in line) {
							// pass
							continue;
						// compute depends, makedepends and checkdepends:
						// list name may contains arch, e.g. depends_x86_64
						// depends, provides, replaces and conflicts in pkgbase section are stored
						// in order to be added after if the list in pkgname is empty,
						// makedepends and checkdepends will be added in depends
						} else if ("depends" in line) {
							if ("depends = " in line || "depends_%s = ".printf (arch) in line) {
								string depend = line.split (" = ", 2)[1];
								if (current_section_is_pkgbase){
									if ("checkdepends" in line) {
										global_checkdepends.append ((owned) depend);
									} else if ("makedepends" in line) {
										global_makedepends.append ((owned) depend);
									} else {
										global_depends.append ((owned) depend);
									}
								} else {
									unowned AURPackage? aur_pkg = pkgnames_table.get (current_section);
									if (aur_pkg != null) {
										aur_pkg.depends_priv.append ((owned) depend);
									}
								}
							}
						} else if ("provides" in line) {
							if ("provides = " in line || "provides_%s = ".printf (arch) in line) {
								string provide = line.split (" = ", 2)[1];
								if (current_section_is_pkgbase) {
									global_provides.append ((owned) provide);
								} else {
									unowned AURPackage? aur_pkg = pkgnames_table.get (current_section);
									if (aur_pkg != null) {
										aur_pkg.provides_priv.append ((owned) provide);
									}
								}
							}
						} else if ("conflicts" in line) {
							if ("conflicts = " in line || "conflicts_%s = ".printf (arch) in line) {
								string conflict = line.split (" = ", 2)[1];
								if (current_section_is_pkgbase) {
									global_conflicts.append ((owned) conflict);
								} else {
									unowned AURPackage? aur_pkg = pkgnames_table.get (current_section);
									if (aur_pkg != null) {
										aur_pkg.conflicts_priv.append ((owned) conflict);
									}
								}
							}
						} else if ("replaces" in line) {
							if ("replaces = " in line || "replaces_%s = ".printf (arch) in line) {
								string replace = line.split (" = ", 2)[1];
								if (current_section_is_pkgbase) {
									global_replaces.append ((owned) replace);
								} else {
									unowned AURPackage? aur_pkg = pkgnames_table.get (current_section);
									if (aur_pkg != null) {
										aur_pkg.replaces_priv.append ((owned) replace);
									}
								}
							}
						// grab validpgpkeys to check if they are imported
						} else if ("validpgpkeys" in line) {
							if ("validpgpkeys = " in line) {
								global_validpgpkeys.append (line.split (" = ", 2)[1]);
							}
						} else if ("pkgname = " in line) {
							string pkgname_found = line.split (" = ", 2)[1];
							current_section = pkgname_found;
							current_section_is_pkgbase = false;
							if (!pkgnames_table.contains (pkgname_found)) {
								var aur_pkg = new AURPackage ();
								aur_pkg.name = pkgname_found;
								aur_pkg.version = version.str;
								aur_pkg.desc = desc;
								aur_pkg.packagebase = pkgbase;
								pkgnames_table.insert (pkgname_found, aur_pkg);
								pkgnames_found.append ((owned) pkgname_found);
							}
						}
					}
					foreach (unowned string pkgname_found in pkgnames_found) {
						already_checked_aur_dep.add (pkgname_found);
					}
					// create fake aur db entries
					foreach (unowned string pkgname_found in pkgnames_found) {
						unowned AURPackage? aur_pkg = pkgnames_table.get (pkgname_found);
						// populate empty list will global ones
						if (global_depends.length () > 0 && aur_pkg.depends.length () == 0) {
							aur_pkg.depends_priv = (owned) global_depends;
						}
						if (global_provides.length () > 0 && aur_pkg.provides.length () == 0) {
							aur_pkg.provides_priv = (owned) global_provides;
						}
						if (global_conflicts.length () > 0 && aur_pkg.conflicts.length () == 0) {
							aur_pkg.conflicts_priv = (owned) global_conflicts;
						}
						if (global_replaces.length () > 0 && aur_pkg.replaces.length () == 0) {
							aur_pkg.replaces_priv = (owned) global_replaces;
						}
						// add checkdepends and makedepends in depends
						if (global_checkdepends.length () > 0 ) {
							foreach (unowned string depend in global_checkdepends) {
								aur_pkg.depends_priv.append (depend);
							}
						}
						if (global_makedepends.length () > 0 ) {
							foreach (unowned string depend in global_makedepends) {
								aur_pkg.depends_priv.append (depend);
							}
						}
						// check deps
						foreach (unowned string dep_string in aur_pkg.depends) {
							Package? pkg = null;
							if (database.has_installed_satisfier (dep_string)) {
								pkg = database.get_installed_satisfier (dep_string);
							} else if (database.has_sync_satisfier (dep_string)) {
								pkg = database.get_sync_satisfier (dep_string);
							}
							if (pkg == null) {
								string dep_name = database.get_alpm_dep_name (dep_string);
								if (!(dep_name in already_checked_aur_dep)) {
									dep_to_check.add ((owned) dep_name);
								}
							}
						}
						// write desc file
						string pkgdir = "%s-%s".printf (pkgname_found, aur_pkg.version);
						string pkgdir_path = "%s/%s".printf (aurdb_path, pkgdir);
						aur_desc_list.add (pkgdir);
						var file = GLib.File.new_for_path (pkgdir_path);
						if (!file.query_exists ()) {
							file.make_directory ();
						}
						file = GLib.File.new_for_path ("%s/desc".printf (pkgdir_path));
						FileOutputStream fos;
						// always recreate desc in case of .SRCINFO modifications
						if (file.query_exists ()) {
							fos = yield file.replace_async (null, false, FileCreateFlags.NONE);
						} else {
							fos = yield file.create_async (FileCreateFlags.NONE);
						}
						// creating a DataOutputStream to the file
						var dos = new DataOutputStream (fos);
						// fake filename
						dos.put_string ("%FILENAME%\n" + "%s-%s-any.pkg.tar.xz\n\n".printf (pkgname_found, aur_pkg.version));
						// name
						dos.put_string ("%NAME%\n%s\n\n".printf (pkgname_found));
						// version
						dos.put_string ("%VERSION%\n%s\n\n".printf (aur_pkg.version));
						// base
						dos.put_string ("%BASE%\n%s\n\n".printf (aur_pkg.packagebase));
						// desc
						dos.put_string ("%DESC%\n%s\n\n".printf (aur_pkg.desc));
						// arch (double %% before ARCH to escape %A)
						dos.put_string ("%%ARCH%\n%s\n\n".printf (arch));
						// depends
						if (aur_pkg.depends.length () > 0) {
							dos.put_string ("%DEPENDS%\n");
							foreach (unowned string depend in aur_pkg.depends) {
								dos.put_string ("%s\n".printf (depend));
							}
							dos.put_string ("\n");
						}
						// conflicts
						if (aur_pkg.conflicts.length () > 0) {
							dos.put_string ("%CONFLICTS%\n");
							foreach (unowned string conflict in aur_pkg.conflicts) {
								dos.put_string ("%s\n".printf (conflict));
							}
							dos.put_string ("\n");
						}
						// provides
						if (aur_pkg.provides.length () > 0) {
							dos.put_string ("%PROVIDES%\n");
							foreach (unowned string provide in aur_pkg.provides) {
								dos.put_string ("%s\n".printf (provide));
							}
							dos.put_string ("\n");
						}
						// replaces
						if (aur_pkg.replaces.length () > 0) {
							dos.put_string ("%REPLACES%\n");
							foreach (unowned string replace in aur_pkg.replaces) {
								dos.put_string ("%s\n".printf (replace));
							}
							dos.put_string ("\n");
						}
					}
					// check signature
					if (global_validpgpkeys.length () > 0) {
						yield check_signature (pkgname, global_validpgpkeys);
					}
				} catch (GLib.Error e) {
					critical ("%s\n", e.message);
					continue;
				}
			}
			if (dep_to_check.length > 0) {
				yield check_aur_dep_list (dep_to_check.data);
			}
		}

		async void check_signature (string pkgname, SList<string> keys) {
			foreach (unowned string key in keys) {
				var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
				try {
					var process = launcher.spawnv ({"gpg", "--with-colons", "--batch", "--list-keys", key});
					yield process.wait_async ();
					if (process.get_if_exited ()) {
						if (process.get_exit_status () != 0) {
							// key is not imported in keyring
							// try to get key infos
							launcher.set_flags (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
							process = launcher.spawnv ({"gpg", "--with-colons", "--batch", "--search-keys", key});
							yield process.wait_async ();
							if (process.get_if_exited ()) {
								if (process.get_exit_status () == 0) {
									var dis = new DataInputStream (process.get_stdout_pipe ());
									string? line;
									while ((line = yield dis.read_line_async ()) != null) {
										// get first uid line
										if ("uid:" in line) {
											string owner = line.split (":", 3)[1];
											if (ask_import_key (pkgname, key, owner)) {
												int status = run_cmd_line ({"gpg", "--with-colons", "--batch", "--recv-keys", key}, null, build_cancellable);
												emit_script_output ("");
												if (status != 0) {
													emit_error (dgettext (null, "key %s could not be imported").printf (key), {});
												}
											}
											break;
										}
									}
								}
							}
						}
					}
				} catch (Error e) {
					critical ("%s\n", e.message);
				} 
			}
		}

		public bool run () {
			bool success = true;
			if (sysupgrading ||
				to_install.length > 0 ||
				to_remove.length > 0 ||
				to_load.length > 0 ||
				to_build.length > 0 ) {
				success = trans_run_real ();
				database.refresh ();
				if (success) {
					if (to_build_queue.get_length () != 0) {
						success = get_authorization ();
						if (success) {
							success = build_aur_packages ();
							database.refresh ();
						}
						#if ENABLE_SNAP
						if (snap_to_install.length > 0 ||
							snap_to_remove.length > 0) {
							success = run_snap_transaction ();
							database.refresh ();
						}
						#endif
						disconnecting_signals ();
					#if ENABLE_SNAP
					} else if (snap_to_install.length > 0 ||
								snap_to_remove.length > 0) {
						success = run_snap_transaction ();
						database.refresh ();
						disconnecting_signals ();
					#endif
					} else {
						disconnecting_signals ();
						if (sysupgrading) {
							sysupgrading = false;
						}
						emit_action (dgettext (null, "Transaction successfully finished") + ".");
					}
				} else {
					disconnecting_signals ();
					to_build_queue.clear ();
					#if ENABLE_SNAP
					snap_to_install.remove_all ();
					snap_to_remove.remove_all ();
					#endif
					handle_error (get_current_error ());
				}
				to_install.remove_all ();
				to_remove.remove_all ();
				to_load.remove_all ();
				to_build.remove_all ();
				temporary_ignorepkgs.remove_all ();
			#if ENABLE_SNAP
			} else if (snap_to_install.length > 0 ||
						snap_to_remove.length > 0) {
				emit_action (dgettext (null, "Preparing") + "...");
				start_preparing ();
				// ask confirmation
				var summary = new TransactionSummary ();
				var iter = HashTableIter<string, SnapPackage> (snap_to_install);
				SnapPackage pkg;
				while (iter.next (null, out pkg)) {
					summary.to_install_priv.append (pkg);
				}
				iter = HashTableIter<string, SnapPackage> (snap_to_remove);
				while (iter.next (null, out pkg)) {
					summary.to_remove_priv.append (pkg);
				}
				if (ask_commit (summary)) {
					stop_preparing ();
					connecting_signals ();
					success = run_snap_transaction ();
					disconnecting_signals ();
				} else {
					stop_preparing ();
					emit_action (dgettext (null, "Transaction cancelled") + ".");
					success = false;
				}
			#endif
			}
			return success;
		}

		void add_optdeps () {
			var to_add_to_install = new GenericSet<string?> (str_hash, str_equal);
			foreach (unowned string name in to_install) {
				// do not check if reinstall
				if (!database.is_installed_pkg (name)) {
					List<string> uninstalled_optdeps = database.get_uninstalled_optdeps (name);
					var real_uninstalled_optdeps = new GenericArray<string> ();
					foreach (unowned string optdep in uninstalled_optdeps) {
						string optdep_name = optdep.split (": ", 2)[0];
						if (!(optdep_name in to_install) && !(optdep_name in to_add_to_install)) {
							real_uninstalled_optdeps.add (optdep);
						}
					}
					if (real_uninstalled_optdeps.length > 0) {
						foreach (unowned string optdep in choose_optdeps (name, real_uninstalled_optdeps.data)) {
							string optdep_name = optdep.split (": ", 2)[0];
							to_add_to_install.add (optdep_name);
						}
					}
				}
			}
			foreach (unowned string name in to_add_to_install) {
				add_pkg_to_install (name);
				add_pkg_to_mark_as_dep (name);
			}
		}

		bool trans_run_real () {
			if (!wait_for_lock ()) {
				return false;
			}
			connecting_signals ();
			add_optdeps ();
			if (sysupgrading) {
				transaction_interface.set_enable_downgrade (database.config.enable_downgrade);
				if (database.config.check_aur_updates) {
					// add aur updates
					var aur_updates = database.get_aur_updates ();
					foreach (unowned AURPackage aur_update in aur_updates) {
						if (!(aur_update.name in temporary_ignorepkgs)) {
							add_aur_pkg_to_build (aur_update.name);
						}
					}
				}
			}
			if (to_build.length > 0) {
				// get authorization now before a potentially long task
				if (!get_authorization ()) {
					return false;
				}
				// set building to allow cancellation
				building = true;
				build_cancellable.reset ();
				compute_aur_build_list ();
				building = false;
				if (build_cancellable.is_cancelled ()) {
					return false;
				}
			}
			return transaction_interface.trans_run ();
		}

		bool wait_for_lock () {
			bool success = true;
			if (transaction_interface.get_lock ()) {
				return true;
			} else {
				waiting = true;
				start_waiting ();
				emit_action (dgettext (null, "Waiting for another package manager to quit") + "...");
				int pass = 0;
				Timeout.add (200, () => {
					if (!waiting) {
						stop_waiting ();
						success = false;
						loop.quit ();
						return false;
					}
					waiting = !transaction_interface.get_lock ();
					if (waiting) {
						pass++;
						// wait 10 min max
						if (pass == 600) {
							waiting = false;
							success = false;
						}
					}
					if (!waiting) {
						stop_waiting ();
						loop.quit ();
					}
					return waiting;
				});
				loop.run ();
			}
			return success;
		}

		public void set_flags (int flags) {
			transaction_interface.set_trans_flags (flags);
		}

		public void add_pkg_to_install (string name) {
			to_install.add (name);
			transaction_interface.add_pkg_to_install (name);
		}

		public void add_pkg_to_remove (string name) {
			to_remove.add (name);
			transaction_interface.add_pkg_to_remove (name);
		}

		public void add_path_to_load (string path) {
			to_load.add (path);
			transaction_interface.add_path_to_load (path);
		}

		public void add_aur_pkg_to_build (string name) {
			to_build.add (name);
			transaction_interface.add_aur_pkg_to_build (name);
		}

		public void add_temporary_ignore_pkg (string name) {
			temporary_ignorepkgs.add (name);
			transaction_interface.add_temporary_ignore_pkg (name);
		}

		public void add_overwrite_file (string glob) {
			transaction_interface.add_overwrite_file (glob);
		}

		public void add_pkg_to_mark_as_dep (string name) {
			transaction_interface.add_pkg_to_mark_as_dep (name);
		}

		public void add_pkgs_to_upgrade (bool force_refresh) {
			if (force_refresh) {
				transaction_interface.set_force_refresh ();
			}
			transaction_interface.set_sysupgrade ();
			sysupgrading = true;
		}

		#if ENABLE_SNAP
		public void add_snap_to_install (SnapPackage pkg) {
			snap_to_install.insert (pkg.name, pkg);
		}

		public void add_snap_to_remove (SnapPackage pkg) {
			snap_to_remove.insert (pkg.name, pkg);
		}

		bool run_snap_transaction () {
			var snap_to_install_array = new GenericArray<string> (snap_to_install.length);
			var snap_to_remove_array = new GenericArray<string> (snap_to_remove.length);
			var iter = HashTableIter<string, SnapPackage> (snap_to_install);
			unowned string name;
			while (iter.next (out name, null)) {
				snap_to_install_array.add (name);
			}
			iter = HashTableIter<string, SnapPackage> (snap_to_remove);
			while (iter.next (out name, null)) {
				snap_to_remove_array.add (name);
			}
			snap_to_install.remove_all ();
			snap_to_remove.remove_all ();
			return transaction_interface.snap_trans_run (snap_to_install_array.data, snap_to_remove_array.data);
		}
		#endif

		string remove_bash_colors (string msg) {
			Regex regex = /\x1B\[[0-9;]*[JKmsu]/;
			try {
				return regex.replace (msg, -1, 0, "");
			} catch (Error e) {
				return msg;
			}
		}

		public virtual int run_cmd_line (string[] args, string? working_directory, Cancellable cancellable) {
			int status = 1;
			var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_INHERIT | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
			if (working_directory != null) {
				launcher.set_cwd (working_directory);
			}
			launcher.set_environ (Environ.get ());
			try {
				Subprocess process = launcher.spawnv (args);
				var dis = new DataInputStream (process.get_stdout_pipe ());
				string? line = null;
				dis.read_line_async.begin (Priority.DEFAULT, cancellable, (obj, res) => {
					try {
						line = dis.read_line_async.end (res);
					} catch (Error e) {
						critical ("%s\n", e.message);
					}
					loop.quit ();
				});
				loop.run ();
				while (line != null) {
					if (cancellable.is_cancelled ()) {
						break;
					}
					emit_script_output (remove_bash_colors (line));
					dis.read_line_async.begin (Priority.DEFAULT, cancellable, (obj, res) => {
						try {
							line = dis.read_line_async.end (res);
						} catch (Error e) {
							critical ("%s\n", e.message);
						}
						loop.quit ();
					});
					loop.run ();
				}
				process.wait_async.begin (cancellable, (obj, res) => {
					try {
						process.wait_async.end (res);
						if (process.get_if_exited ()) {
							status = process.get_exit_status ();
						}
					} catch (Error e) {
						// cancelled
						process.send_signal (Posix.Signal.INT);
						process.send_signal (Posix.Signal.KILL);
					}
					loop.quit ();
				});
				loop.run ();
			} catch (Error e) {
				critical ("%s\n", e.message);
			}
			return status;
		}

		bool build_aur_packages () {
			bool success = true;
			while (to_build_queue.length > 0) {
				string pkgname = to_build_queue.pop_head ();
				build_cancellable.reset ();
				emit_script_output ("");
				emit_action (dgettext (null, "Building %s").printf (pkgname) + "...");
				important_details_outpout (false);
				var built_pkgs = new GenericSet<string?> (str_hash, str_equal);
				string pkgdir = Path.build_path ("/", database.config.aur_build_dir, pkgname);
				// building
				building = true;
				start_building ();
				int status = run_cmd_line ({"makepkg", "-cCf"}, pkgdir, build_cancellable);
				if (build_cancellable.is_cancelled ()) {
					status = 1;
				}
				if (status == 0) {
					// get built pkgs path
					var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE);
					launcher.set_cwd (pkgdir);
					try {
						Subprocess process = launcher.spawnv ({"makepkg", "--packagelist"});
						process.wait_async.begin (null, () => {
							loop.quit ();
						});
						loop.run ();
						if (process.get_if_exited ()) {
							status = process.get_exit_status ();
						}
						if (status == 0) {
							var dis = new DataInputStream (process.get_stdout_pipe ());
							string? line = null;
							dis.read_line_async.begin (Priority.DEFAULT, null, (obj, res) => {
								try {
									line = dis.read_line_async.end (res);
								} catch (Error e) {
									critical ("%s\n", e.message);
								}
								loop.quit ();
							});
							loop.run ();
							while (line != null) {
								var file = GLib.File.new_for_path (line);
								string filename = file.get_basename ();
								string name_version_release = filename.slice (0, filename.last_index_of_char ('-'));
								string name_version = name_version_release.slice (0, name_version_release.last_index_of_char ('-'));
								string name = name_version.slice (0, name_version.last_index_of_char ('-'));
								if (name in aur_pkgs_to_install) {
									built_pkgs.add (line);
								}
								dis.read_line_async.begin (Priority.DEFAULT, null, (obj, res) => {
									try {
										line = dis.read_line_async.end (res);
									} catch (Error e) {
										critical ("%s\n", e.message);
									}
									loop.quit ();
								});
								loop.run ();
							}
						}
					} catch (Error e) {
						critical ("%s\n", e.message);
						status = 1;
					}
				}
				stop_building ();
				building = false;
				if (status == 0 && built_pkgs.length > 0) {
					foreach (unowned string name in built_pkgs) {
						add_path_to_load (name);
					}
					transaction_interface.set_no_confirm_commit ();
					emit_script_output ("");
					success = transaction_interface.trans_run ();
					if (!success) {
						break;
					}
				} else {
					important_details_outpout (true);
					to_build_queue.clear ();
					success = false;
					break;
				}
			}
			return success;
		}

		public void cancel () {
			if (building) {
				build_cancellable.cancel ();
			} else if (waiting) {
				waiting = false;
			} else {
				transaction_interface.trans_cancel ();
			}
			emit_script_output ("");
			emit_action (dgettext (null, "Transaction cancelled") + ".");
			emit_script_output ("");
		}

		int on_choose_provider (string depend, string[] providers) {
			return choose_provider (depend, providers);
		}

		void handle_error (ErrorInfos error) {
			if (error.message != "") {
				emit_error (error.message, error.details);
			}
		}

		bool on_ask_commit (TransactionSummaryStruct summary_struct) {
			if (build_cancellable.is_cancelled ()) {
				return false;
			} else {
				var summary = new TransactionSummary.from_struct (summary_struct);
				#if ENABLE_SNAP
				var iter = HashTableIter<string, SnapPackage> (snap_to_install);
				SnapPackage pkg;
				while (iter.next (null, out pkg)) {
					summary.to_install_priv.append (pkg);
				}
				iter = HashTableIter<string, SnapPackage> (snap_to_remove);
				while (iter.next (null, out pkg)) {
					summary.to_remove_priv.append (pkg);
				}
				#endif
				// populate build queue
				to_build_queue.clear ();
				foreach (unowned string name in summary_struct.aur_pkgbases_to_build) {
					to_build_queue.push_tail (name);
				}
				aur_pkgs_to_install.remove_all ();
				foreach (unowned PackageStruct infos in summary_struct.to_build) {
					aur_pkgs_to_install.add (infos.name);
				}
				return ask_commit (summary);
			}
		}

		bool on_ask_edit_build_files (TransactionSummaryStruct summary_struct) {
			var summary = new TransactionSummary.from_struct (summary_struct);
			#if ENABLE_SNAP
			var iter = HashTableIter<string, SnapPackage> (snap_to_install);
			SnapPackage pkg;
			while (iter.next (null, out pkg)) {
				summary.to_install_priv.append (pkg);
			}
			iter = HashTableIter<string, SnapPackage> (snap_to_remove);
			while (iter.next (null, out pkg)) {
				summary.to_remove_priv.append (pkg);
			}
			#endif
			return ask_edit_build_files (summary);
		}

		void on_edit_build_files (string[] pkgnames) {
			edit_build_files (pkgnames);
		}

		void on_emit_action (string action) {
			emit_action (action);
		}

		void on_emit_action_progress (string action, string status, double progress) {
			emit_action_progress (action, status, progress);
		}

		void on_emit_download_progress (string action, string status, double progress) {
			emit_download_progress (action, status, progress);
		}

		void on_emit_hook_progress (string action, string details, string status, double progress) {
			emit_hook_progress (action, details, status, progress);
		}

		void on_emit_script_output (string message) {
			emit_script_output (message);
		}

		void on_emit_warning (string message) {
			emit_warning (message);
		}

		void on_emit_error (string message, string[] details) {
			emit_error (message, details);
		}

		void on_important_details_outpout (bool must_show) {
			important_details_outpout (must_show);
		}

		void on_start_downloading () {
			start_downloading ();
		}

		void on_stop_downloading () {
			stop_downloading ();
		}

		void connecting_signals () {
			transaction_interface.choose_provider.connect (on_choose_provider);
			transaction_interface.compute_aur_build_list.connect (compute_aur_build_list);
			transaction_interface.ask_commit.connect (on_ask_commit);
			transaction_interface.ask_edit_build_files.connect (on_ask_edit_build_files);
			transaction_interface.edit_build_files.connect (on_edit_build_files);
			transaction_interface.emit_action.connect (on_emit_action);
			transaction_interface.emit_action_progress.connect (on_emit_action_progress);
			transaction_interface.emit_download_progress.connect (on_emit_download_progress);
			transaction_interface.emit_hook_progress.connect (on_emit_hook_progress);
			transaction_interface.emit_script_output.connect (on_emit_script_output);
			transaction_interface.emit_warning.connect (on_emit_warning);
			transaction_interface.emit_error.connect (on_emit_error);
			transaction_interface.important_details_outpout.connect (on_important_details_outpout);
			transaction_interface.start_downloading.connect (on_start_downloading);
			transaction_interface.stop_downloading.connect (on_stop_downloading);
		}

		void disconnecting_signals () {
			transaction_interface.choose_provider.disconnect (on_choose_provider);
			transaction_interface.compute_aur_build_list.disconnect (compute_aur_build_list);
			transaction_interface.ask_commit.disconnect (on_ask_commit);
			transaction_interface.ask_edit_build_files.disconnect (on_ask_edit_build_files);
			transaction_interface.edit_build_files.disconnect (on_edit_build_files);
			transaction_interface.emit_action.disconnect (on_emit_action);
			transaction_interface.emit_action_progress.disconnect (on_emit_action_progress);
			transaction_interface.emit_download_progress.disconnect (on_emit_download_progress);
			transaction_interface.emit_hook_progress.disconnect (on_emit_hook_progress);
			transaction_interface.emit_script_output.disconnect (on_emit_script_output);
			transaction_interface.emit_warning.disconnect (on_emit_warning);
			transaction_interface.emit_error.disconnect (on_emit_error);
			transaction_interface.important_details_outpout.disconnect (on_important_details_outpout);
			transaction_interface.start_downloading.disconnect (on_start_downloading);
			transaction_interface.stop_downloading.disconnect (on_stop_downloading);
		}
	}
}
