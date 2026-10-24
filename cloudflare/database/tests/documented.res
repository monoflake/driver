/***
 * Time Travel's restore answered by the example of the page below, copied as `docs/code.md` asks.
 * https://developers.cloudflare.com/api/resources/d1/subresources/database/subresources/time_travel/methods/restore/
 */

let restored = `{
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
    "bookmark": "00000001-00000002-00004e2f-0a83ea2fceebc654de0640c422be4653",
    "message": "Database restored successfully",
    "previous_bookmark": "00000001-00000002-00004e2f-0a83ea2fceebc654de0640c422be4653"
  },
  "success": true
}`

// The errors envelope the page documents, its example's own error, `success` false.
let refused = `{
  "errors": [
    {
      "code": 1000,
      "message": "message"
    }
  ],
  "messages": [],
  "result": null,
  "success": false
}`
