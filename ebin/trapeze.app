{application, trapeze,
 [{description, "RabbitMQ Web Routing Frontend"},
  {vsn, "0.01"},
  {modules, [
    trapeze,
    trapeze_app,
    trapeze_sup,
    trapeze_web,
    trapeze_deps
  ]},
  {registered, []},
  {mod, {trapeze_app, []}},
  {env, []},
  {applications, [kernel, stdlib]}]}.
