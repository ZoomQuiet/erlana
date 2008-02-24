{application, erlana,
 [{description, "erlana"},
  {vsn, "0.01"},
  {modules, [
    erlana,
    erlana_app,
    erlana_sup,
    erlana_web,
    erlana_deps
  ]},
  {registered, []},
  {mod, {erlana_app, []}},
  {env, []},
  {applications, [kernel, stdlib, crypto]}]}.
