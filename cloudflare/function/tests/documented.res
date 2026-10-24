/***
 * The 200 examples of Cloudflare's API reference, each copied as its page shows it, as
 * `docs/code.md` asks a standard's own examples be taken. Each page lies under
 * https://developers.cloudflare.com/api/resources/workers/subresources/ by the path above it.
 */

// scripts/subresources/versions/methods/create/
let versionUploaded = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "resources": {
      "bindings": {},
      "script": {
        "etag": "13a3240e8fb414561b0366813b0b8f42b3e6cfa0d9e70e99835dae83d0d8a794",
        "handlers": [
          "fetch"
        ],
        "last_deployed_from": "api",
        "named_handlers": [
          {
            "handlers": [
              "fetch"
            ],
            "name": "MyClass"
          }
        ]
      },
      "script_runtime": {
        "compatibility_date": "2022-11-08T00:00:00Z",
        "compatibility_flags": [
          "x"
        ],
        "exports": {
          "Admin": {
            "type": "worker",
            "cache": {
              "enabled": true
            },
            "state": "created"
          },
          "Counter": {
            "storage": "sqlite",
            "type": "durable-object",
            "container": "my-container",
            "state": "created"
          },
          "OldCounter": {
            "state": "renamed",
            "type": "durable-object"
          },
          "default": {
            "type": "worker",
            "cache": {
              "enabled": false
            },
            "state": "created"
          }
        },
        "limits": {
          "cpu_ms": 50
        },
        "migration_tag": "v1",
        "usage_model": "standard"
      }
    },
    "id": "18f97339-c287-4872-9bdd-e2135c07ec12",
    "exports_reconciliation": {
      "created": [
        "string"
      ],
      "deleted": [
        "string"
      ],
      "info": [
        {
          "class": "class",
          "message": "message",
          "scenario": "code_class_not_in_exports",
          "namespace_id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
          "referencing_scripts": [
            "string"
          ]
        }
      ],
      "removable_entries": [
        "string"
      ],
      "renamed": [
        {
          "from": "from",
          "to": "to"
        }
      ],
      "transfer_pending": [
        {
          "class": "class",
          "from": "from"
        }
      ],
      "transferred": [
        {
          "class": "class",
          "phase": "committed",
          "to": "to"
        }
      ],
      "updated": [
        "string"
      ],
      "warnings": [
        {
          "class": "class",
          "message": "message",
          "scenario": "code_class_not_in_exports",
          "namespace_id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e"
        }
      ]
    },
    "metadata": {
      "author_email": "user@example.com",
      "author_id": "408cbcdfd4dda4617efef40b04d168a1",
      "created_on": "2022-11-08T17:19:29.176266Z",
      "hasPreview": true,
      "modified_on": "2022-11-08T17:19:29.176266Z",
      "source": "api"
    },
    "number": 1,
    "startup_time_ms": 10
  },
  "success": true
}`

// scripts/methods/update/
let scriptUploaded = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "startup_time_ms": 10,
    "id": "this-is_my_script-01",
    "cache_options": {
      "enabled": true,
      "cross_version_cache": true
    },
    "compatibility_date": "2021-01-01T00:00:00Z",
    "compatibility_flags": [
      "nodejs_compat"
    ],
    "created_on": "2022-05-05T05:15:11.602148Z",
    "entry_point": "index.js",
    "etag": "777f24a43bef5f69174aa69ceaf1dea67968d510a31d1vw3e49d34a0187c06d1",
    "exports": {
      "Admin": {
        "type": "worker",
        "cache": {
          "enabled": true
        },
        "state": "created"
      },
      "Counter": {
        "storage": "sqlite",
        "type": "durable-object",
        "container": "my-container",
        "state": "created"
      },
      "OldCounter": {
        "state": "renamed",
        "type": "durable-object"
      },
      "default": {
        "type": "worker",
        "cache": {
          "enabled": false
        },
        "state": "created"
      }
    },
    "handlers": [
      "fetch"
    ],
    "has_assets": false,
    "has_modules": false,
    "last_deployed_from": "wrangler",
    "logpush": false,
    "migration_tag": "v1",
    "modified_on": "2022-05-20T19:02:56.446492Z",
    "named_handlers": [
      {
        "handlers": [
          "class"
        ],
        "name": "MyDurableObject"
      }
    ],
    "observability": {
      "enabled": true,
      "head_sampling_rate": 0.1,
      "issues": {
        "enabled": true
      },
      "logs": {
        "enabled": true,
        "invocation_logs": true,
        "destinations": [
          "cloudflare"
        ],
        "head_sampling_rate": 0.1,
        "persist": true
      },
      "redact_query_string": false,
      "traces": {
        "destinations": [
          "cloudflare"
        ],
        "enabled": true,
        "head_sampling_rate": 0.1,
        "persist": true,
        "propagation_policy": "authenticated"
      }
    },
    "placement": {
      "mode": "smart",
      "last_analyzed_at": "2025-01-01T00:00:00Z",
      "status": "SUCCESS"
    },
    "placement_mode": "smart",
    "placement_status": "SUCCESS",
    "tag": "e8f70fdbc8b1fb0b8ddb1af166186758",
    "tags": [
      "my-team",
      "my-public-api"
    ],
    "tail_consumers": [
      {
        "service": "my-log-consumer",
        "environment": "production",
        "namespace": "my-namespace"
      }
    ],
    "usage_model": "standard"
  },
  "success": true
}`

// scripts/subresources/subdomain/methods/create/
let subdomainEnabled = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "enabled": false,
    "previews_enabled": false
  },
  "success": true
}`

// scripts/subresources/deployments/methods/create/
let deploymentCreated = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
    "created_on": "2019-12-27T18:11:19.117Z",
    "source": "api",
    "strategy": "percentage",
    "versions": [
      {
        "percentage": 100,
        "version_id": "023e105f-2a42-4f8b-a1c1-73f6a2a30c0f"
      }
    ],
    "annotations": {
      "workers/message": "Deploy bug fix.",
      "workers/triggered_by": "deployment"
    },
    "author_email": "dev@stainless.com"
  },
  "success": true
}`

// scripts/subresources/deployments/methods/list/
let deploymentsListed = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "deployments": [
      {
        "id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
        "created_on": "2019-12-27T18:11:19.117Z",
        "source": "api",
        "strategy": "percentage",
        "versions": [
          {
            "percentage": 100,
            "version_id": "023e105f-2a42-4f8b-a1c1-73f6a2a30c0f"
          }
        ],
        "annotations": {
          "workers/message": "Deploy bug fix.",
          "workers/triggered_by": "deployment"
        },
        "author_email": "dev@stainless.com"
      }
    ]
  },
  "success": true,
  "result_info": {
    "count": 1,
    "page": 1,
    "per_page": 20,
    "total_count": 2000,
    "total_pages": 100
  }
}`

// beta/subresources/workers/subresources/versions/methods/get/
let versionGot = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
    "created_on": "2019-12-27T18:11:19.117Z",
    "number": 0,
    "urls": [
      "https://9387e76d-my-worker.my-subdomain.workers.dev"
    ],
    "annotations": {
      "workers/message": "Fixed bug.",
      "workers/tag": "v1.0.1",
      "workers/triggered_by": "upload"
    },
    "assets": {
      "config": {
        "base_path": "/docs/",
        "html_handling": "auto-trailing-slash",
        "not_found_handling": "404-page",
        "run_worker_first": true
      },
      "jwt": "jwt"
    },
    "author_email": "user@example.com",
    "author_id": "408cbcdfd4dda4617efef40b04d168a1",
    "bindings": [
      {
        "name": "MY_ENV_VAR",
        "text": "my_data",
        "type": "plain_text"
      }
    ],
    "cache_options": {
      "enabled": true,
      "cross_version_cache": true
    },
    "compatibility_date": "2021-01-01T00:00:00Z",
    "compatibility_flags": [
      "nodejs_compat"
    ],
    "containers": [
      {
        "class_name": "MyDurableObject"
      }
    ],
    "exports": {
      "Admin": {
        "type": "worker",
        "cache": {
          "enabled": true
        },
        "state": "created"
      },
      "Counter": {
        "storage": "sqlite",
        "type": "durable-object",
        "container": "my-container",
        "state": "created"
      },
      "OldCounter": {
        "state": "renamed",
        "type": "durable-object"
      },
      "default": {
        "type": "worker",
        "cache": {
          "enabled": false
        },
        "state": "created"
      }
    },
    "exports_reconciliation": {
      "created": [
        "string"
      ],
      "deleted": [
        "string"
      ],
      "info": [
        {
          "class": "class",
          "message": "message",
          "scenario": "code_class_not_in_exports",
          "namespace_id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e",
          "referencing_scripts": [
            "string"
          ]
        }
      ],
      "removable_entries": [
        "string"
      ],
      "renamed": [
        {
          "from": "from",
          "to": "to"
        }
      ],
      "transfer_pending": [
        {
          "class": "class",
          "from": "from"
        }
      ],
      "transferred": [
        {
          "class": "class",
          "phase": "committed",
          "to": "to"
        }
      ],
      "updated": [
        "string"
      ],
      "warnings": [
        {
          "class": "class",
          "message": "message",
          "scenario": "code_class_not_in_exports",
          "namespace_id": "182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e"
        }
      ]
    },
    "limits": {
      "cpu_ms": 50,
      "subrequests": 1000
    },
    "main_module": "index.js",
    "migration_tag": "v1",
    "migrations": {},
    "modules": [
      {
        "content_base64": "ZXhwb3J0IGRlZmF1bHQgewogIGFzeW5jIGZldGNoKHJlcXVlc3QsIGVudiwgY3R4KSB7CiAgICByZXR1cm4gbmV3IFJlc3BvbnNlKCdIZWxsbyBXb3JsZCEnKQogIH0KfQ==",
        "content_type": "application/javascript+module",
        "name": "index.js"
      }
    ],
    "package_dependencies": [
      {
        "installedVersion": "4.17.22",
        "name": "lodash",
        "packageJsonVersion": "^4.17.21"
      }
    ],
    "placement": {
      "mode": "smart"
    },
    "source": "wrangler",
    "startup_time_ms": 10,
    "usage_model": "standard"
  },
  "success": true
}`

// scripts/methods/delete/
let scriptDeleted = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "success": true,
  "result": {}
}`

// subdomains/methods/get/
let subdomainGot = `{
  "errors": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "messages": [
    {
      "code": 1000,
      "message": "message",
      "documentation_url": "documentation_url",
      "source": {
        "pointer": "pointer"
      }
    }
  ],
  "result": {
    "subdomain": "my-subdomain"
  },
  "success": true
}`

// https://developers.cloudflare.com/workers/observability/errors/ names code 10007, in the errors
// envelope every page above documents.
let notFound = `{
  "errors": [
    {
      "code": 10007,
      "message": "Worker or workers.dev subdomain not found."
    }
  ],
  "messages": [],
  "result": null,
  "success": false
}`
