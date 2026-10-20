"""Compact DocType reference: one line per field, from the running dev site.

Cheaper than reading DocType JSON: Employee is 939 lines of JSON, about 80 lines here.
Run through ./dev:

    ./dev meta Employee              fields (no layout breaks), custom fields marked
    ./dev meta Employee -a           also section/column/tab breaks
    ./dev meta "Leave Application" -l   links: workflows, custom fields, property setters, child tables
    ./dev meta overtime              no exact match: lists DocTypes whose name contains the term
"""

import sys

import frappe

LAYOUT = {"Section Break", "Column Break", "Tab Break", "HTML", "Heading", "Fold", "Button"}
WITH_OPTIONS = {"Link", "Dynamic Link", "Table", "Table MultiSelect", "Select"}


def field_line(df):
	bits = [df.fieldname, df.fieldtype, repr(df.label or "")]
	if df.fieldtype in WITH_OPTIONS and df.options:
		bits.append("->" + df.options.replace("\n", "|"))
	flags = [name for name in ("reqd", "read_only", "hidden", "unique", "in_list_view") if df.get(name)]
	if df.get("is_custom_field"):
		flags.append("CUSTOM")
	if df.get("fetch_from"):
		flags.append("fetch=" + df.fetch_from)
	if df.get("depends_on"):
		flags.append("depends_on=" + df.depends_on)
	if df.get("default"):
		flags.append("default=" + str(df.default))
	return "  ".join(bits + flags)


def main(site, target, *opts):
	frappe.init(site=site, sites_path=".")
	frappe.connect()
	try:
		if not frappe.db.exists("DocType", target):
			matches = frappe.get_all(
				"DocType", filters={"name": ["like", f"%{target}%"]}, fields=["name", "module"], order_by="name"
			)
			print(f"No DocType '{target}'. Matches:" if matches else f"No DocType matching '{target}'.")
			for m in matches:
				print(f"  {m.name}  ({m.module})")
			return

		meta = frappe.get_meta(target)
		app = frappe.db.get_value("Module Def", meta.module, "app_name")
		kind = "child" if meta.istable else "single" if meta.issingle else "submittable" if meta.is_submittable else "doc"
		print(f"# {meta.name}  [{kind}]  module={meta.module}  app={app}  naming={meta.autoname or '-'}")
		for df in meta.fields:
			if df.fieldtype in LAYOUT and "-a" not in opts:
				continue
			print(field_line(df))

		if "-l" in opts:
			print("\n# links")
			for wf in frappe.get_all("Workflow", filters={"document_type": target}, fields=["name", "is_active"]):
				print(f"workflow: {wf.name}  active={wf.is_active}")
			for ps in frappe.get_all(
				"Property Setter",
				filters={"doc_type": target},
				fields=["field_name", "property", "value", "module"],
			):
				print(f"property setter: {ps.field_name or '(doctype)'}.{ps.property}={ps.value}  module={ps.module}")
			children = sorted({df.options for df in meta.fields if df.fieldtype in ("Table", "Table MultiSelect")})
			if children:
				print("child tables: " + ", ".join(children))
			linked = frappe.get_all("DocField", filters={"options": target, "fieldtype": "Link"}, pluck="parent")
			if linked:
				print("linked from: " + ", ".join(sorted(set(linked))[:40]))
	finally:
		frappe.destroy()


if __name__ == "__main__":
	if len(sys.argv) < 3:
		print(__doc__)
		sys.exit(1)
	main(*sys.argv[1:])
