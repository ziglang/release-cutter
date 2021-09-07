# Release Cutter

Helpful scripts for cutting a Zig release.

## GitHub GraphQL Snippets

### List All the Tiers

These are hard-coded into the script; if these change the .zig code must be updated.

```gql
{
  organization(login: "ziglang") {
    sponsorsListing {
      tiers(first: 20) {
        nodes {
          id
          name
          description
        }
      }
    }
  }
}
```

Output: (2021-09-06)

```
{
  "data": {
    "organization": {
      "sponsorsListing": {
        "tiers": {
          "nodes": [
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM5NDY1",
              "name": "$5 a month",
              "description": "A meaningful contribution for a nimble organization. \r\n"
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM2Mjgy",
              "name": "$10 a month",
              "description": "Let's reclaim control of Open Source software development!"
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM2Mjgz",
              "name": "$15 a month",
              "description": "Like the previous tier, but it seems the compiler decided to add some padding. Thank you very much!"
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM0MDcy",
              "name": "$25 a month",
              "description": "This funds 30 minutes of paid developer work per month. Brilliant!"
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM0MDcx",
              "name": "$50 a month",
              "description": "This funds one hour of paid developer work per month.\r\n\r\nAs a reward:\r\n\r\n* Your name listed in the official release notes with every release of Zig."
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM0MDcw",
              "name": "$100 a month",
              "description": "This funds two hours of paid developer work per month. With just 40 other people donating this amount, it would be enough to hire someone.\r\n\r\nAs a reward:\r\n\r\n* Your name **with a hyperlink to your home page** listed in the official release notes with every release of Zig."
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM0MDc1",
              "name": "$200 a month",
              "description": "This funds 4 hours of paid developer work per month. With just 20 other people donating this amount, it would be enough to hire someone.\r\n\r\nAs a reward:\r\n * Your name **with a hyperlink to your home page** listed in the official release notes with every release of Zig.\r\n * Your name listed at the bottom of ziglang.org landing page."
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjM0MDc3",
              "name": "$400 a month",
              "description": "This funds 8 hours of paid developer work per month. With just 10 other people donating this amount, it would be enough to hire someone.\r\n\r\nAs a reward:\r\n\r\n * Your name **with a hyperlink to your home page** listed in the official release notes with every release of Zig.\r\n * Your name **with a hyperlink to your home page** listed at the bottom of ziglang.org landing page.\r\n"
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjUwMDE0",
              "name": "$1,200 a month",
              "description": "This funds 24 hours of paid developer work per month.\r\n\r\nA good option for companies that intend to donate using GitHub Sponsors.\r\nPlease contact us for alternative donation methods and any other requests.\r\n"
            },
            {
              "id": "MDEyOlNwb25zb3JzVGllcjUwMjgx",
              "name": "$5,000 a month",
              "description": "This funds 100 hours of paid developer work per month!\r\n\r\nWith your help, we're going to take off every Zig at the speed of light!\r\n"
            }
          ]
        }
      }
    }
  }
}
```

### Obtain the Full Data Set

Ideally the tool would do this automatically but I didn't bother to set that up
yet, and I'm not willing to do it in any other language than Zig. Pull requests
using other programming languages will be REJECTED!!!

In the meantime, there's this
[explorer thing](https://docs.github.com/en/graphql/overview/explorer).

```gql
query GetSponsors($tierId: String) {
  organization(login: "ziglang") {
    sponsors(tierId: $tierId, first: 100) {
      nodes {
        ... on User {
          id
          name
          login
          twitterUsername
          websiteUrl
        }
        ... on Organization {
          id
          name
          login
          twitterUsername
          websiteUrl
        }
      }
    }
  }
}
```

* Do the query multiple times, annotating each result with its `tierId`
  (I couldn't figure out how to do this directly with GraphQL. Annotate
  each one by saving each query into a file named `tiers-data/$tierId.json`.
  - `{"tierId": "MDEyOlNwb25zb3JzVGllcjUwMjgx"}`
  - `{"tierId": "MDEyOlNwb25zb3JzVGllcjUwMDE0"}`
  - `{"tierId": "MDEyOlNwb25zb3JzVGllcjM0MDc3"}`
  - `{"tierId": "MDEyOlNwb25zb3JzVGllcjM0MDc1"}`
  - `{"tierId": "MDEyOlNwb25zb3JzVGllcjM0MDcw"}`
  - `{"tierId": "MDEyOlNwb25zb3JzVGllcjM0MDcx"}`

### Command Line Application

Now run the `sponsors-html` tool with no arguments and follow the help
instructions that it prints.

