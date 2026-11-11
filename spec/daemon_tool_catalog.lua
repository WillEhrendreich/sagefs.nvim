-- The daemon's MCP tool catalog, for specs. Not a spec: busted runs only *_spec files.
--
-- Source: every `member _.<name>` of `SageFsTools` in SageFs/McpTools.fs at SageFs
-- commit 49c02f30 (v0.6.945, 78 tools). The daemon builds its tool list by reflection
-- over that type (McpTools.fs, "which tools exist"), so this list is the tool names.
-- Copied by hand; refresh it when the plugin starts to speak to a newer daemon:
--   git show <sha>:SageFs/McpTools.fs | grep -oE 'member _\.[a-z_]+' | sort -u
--
-- `params` lists the argument names of the tools the plugin calls, read from the same
-- file (the F# parameter names are the JSON argument names).
local M = {}

M.tools = {
  "acquire_claim",
  "acquire_full_build_lease",
  "acquire_run_app_lease",
  "acquire_test_suite_lease",
  "cancel_eval",
  "check_fsharp_code",
  "coverage_intel",
  "create_bare_session",
  "create_project_session",
  "create_solution_session",
  "decompose_pipeline",
  "delegate_conductor",
  "diagnose",
  "disable_hot_reload",
  "discover_features",
  "enable_hot_reload",
  "explain_test_failure",
  "explain_test_run",
  "export_notebook",
  "export_session_transcript",
  "get_available_projects",
  "get_cell_dependencies",
  "get_cohort_status",
  "get_daemon_status",
  "get_elm_state",
  "get_eval_diff",
  "get_eval_timeline",
  "get_friction_report",
  "get_friction_summary",
  "get_message_journal",
  "get_recent_fsi_events",
  "get_session_filmstrip",
  "get_session_status",
  "get_startup_info",
  "get_workspace_hygiene",
  "hard_reset_fsi_session",
  "impact_forecast",
  "join_cohort",
  "leave_cohort",
  "list_members",
  "list_references",
  "list_runnable_projects",
  "list_sessions",
  "list_tests",
  "load_fsharp_script",
  "manage_local_data",
  "manage_scratch_pad",
  "mint_member",
  "nudge_value",
  "plan_ripple",
  "preview_what_if",
  "profile",
  "reassign_claim",
  "release_claim",
  "release_work_lease",
  "report_friction",
  "request_landing",
  "reset_fsi_session",
  "reset_hot_reload_state",
  "resolve_veto",
  "revoke_member",
  "run_app",
  "run_tests",
  "seat_conductor",
  "send_fsharp_code",
  "set_integration_ref",
  "set_reflection_read_mode",
  "stop_app",
  "stop_session",
  "suggest_next_action",
  "suggest_next_cell",
  "suggest_repair",
  "switch_session",
  "switch_workflow",
  "targeted_verify",
  "tidy_workspace",
  "veto_landing",
  "withdraw_landing",
}

M.params = {
  delegate_conductor = { "agentName", "toMember", "working_directory" },
  veto_landing = { "agentName", "landingId", "reason", "working_directory" },
  resolve_veto = { "agentName", "landingId", "working_directory" },
  withdraw_landing = { "agentName", "landingId", "working_directory" },
  mint_member = { "agentName", "role", "scope", "ttl_minutes", "working_directory", "session_id" },
  revoke_member = { "agentName", "member_id", "working_directory" },
  get_cohort_status = { "working_directory" },
  get_workspace_hygiene = { "working_directory" },
}

--- The tool names as a set.
function M.name_set()
  local set = {}
  for _, n in ipairs(M.tools) do set[n] = true end
  return set
end

return M
