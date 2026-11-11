# Release notes draft

The release step reads this file, folds it into the GitHub release, and deletes it.

## Changed: the default header (DossierUI)

`DossierView` now draws the standard `DossierHeader`: a breadcrumb (project title, then the
character's name), the role as a badge, the update state, **Rebuild**, and then the host's
accessory. It replaces the old plain header with Rebuild and an accessory.

Escribir is the only host of `DossierView`, so no other app needs to migrate.

New in `DossierUI`:

- `DossierProjectContext(title:bundlePath:)`, and `DossierView(... project:)`.
- `DossierView(... onField:)`, called with the key of each field clicked in the page.
- `DossierView(... header:)`, to draw your own header from a `DossierHeaderModel`.
- `DossierHeader` and `DossierHeaderModel` are public.

## Breaking: `DossierView`'s generic parameter

The generic parameter of `DossierView` is now `Header`, the type of the header. It was
`Accessory`. Call sites that use the initializers compile unchanged. Code that names the type,
such as `DossierView<MyAccessory>`, must change: name `DossierHeader<MyAccessory>` instead, or
let the type be inferred.

## Dependency: SwiftReparto 0.3.0

The SwiftReparto floor is now 0.3.0, for `CastMember.displayName`, which the header shows.
