/**
 * Lists that can grow (applications, candidates, events) load one window of
 * this many rows at a time and append on "Load more" — never the whole table.
 * Order the query by a stable column, otherwise a window boundary can skip or
 * repeat a row.
 */
export const LIST_PAGE = 50
