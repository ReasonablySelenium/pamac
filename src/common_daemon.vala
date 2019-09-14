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
	public struct PackageStruct {
		public string name;
		public string app_name;
		public string version;
		public string installed_version;
		public string desc;
		public string long_desc;
		public string repo;
		public string launchable;
		public uint64 installed_size;
		public uint64 download_size;
		public string url;
		public string icon;
		public uint64 installdate;

		public PackageStruct () {
			name = "";
			app_name = "";
			version = "";
			installed_version = "";
			desc = "";
			long_desc = "";
			repo = "";
			launchable = "";
			url = "";
			icon = "";
		}
	}

	public struct TransactionSummaryStruct {
		public PackageStruct?[] to_install;
		public PackageStruct?[] to_upgrade;
		public PackageStruct?[] to_downgrade;
		public PackageStruct?[] to_reinstall;
		public PackageStruct?[] to_remove;
		public PackageStruct?[] to_build;
		public PackageStruct?[] aur_conflicts_to_remove;
		public string[] aur_pkgbases_to_build;
	}

	public struct ErrorInfos {
		public string message;
		public string[] details;
		public ErrorInfos () {
			message = "";
		}
	}
}

