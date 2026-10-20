"""Run a Python file against a site with frappe connected, then commit.

    ./dev run development/scratch/make_exit_permit.py

The file runs as a script with `frappe` already imported and connected as Administrator.
In developer mode, DocTypes, print formats, reports and workspaces it saves with a
erp_custom module are written into the app as files, exactly as if clicked in the Desk.
On an exception the script's data changes are rolled back, but two things are not:
creating or altering a DocType (MariaDB commits DDL immediately) and the files developer
mode already wrote into the app. After a failed run, check `git status` in the app and
whether the DocType exists, and clean up before rerunning.
"""

import runpy
import sys

import frappe


def main(site, path):
	frappe.init(site=site, sites_path=".")
	frappe.connect()
	frappe.set_user("Administrator")
	try:
		runpy.run_path(path, init_globals={"frappe": frappe}, run_name="__main__")
		frappe.db.commit()
	except BaseException:
		frappe.db.rollback()
		raise
	finally:
		frappe.destroy()


if __name__ == "__main__":
	if len(sys.argv) != 3:
		print(__doc__)
		sys.exit(1)
	main(*sys.argv[1:])
