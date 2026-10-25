# UI icon sources

Generated with Codex (gpt-image) for the inventory HUD. Rubber-hose style, transparent PNGs.

| File | Used by | Paste the uploaded id into |
| --- | --- | --- |
| `SnowEgg.png` | Snow Egg stack card, full toast | `ItemDefinitions.Items.SnowEgg.Icon` |
| `IceEgg.png` | Ice Egg stack card, full toast | `ItemDefinitions.Items.IceEgg.Icon` |
| `AuroraEgg.png` | Aurora Egg stack card, full toast | `ItemDefinitions.Items.AuroraEgg.Icon` |
| `EggBasket.png` | "EGGS" header | `UiAssets.EggBasket` |

Rojo can't upload images to Roblox, so these need one manual step:

1. In Studio, open **View > Asset Manager > Bulk Import** and select the four PNGs.
2. Right-click each uploaded image > **Copy Asset ID**.
3. Paste it as `"rbxassetid://<id>"` into the file in the table above.

Until an id is set, the HUD draws an outlined cartoon egg in the item's colour, and the basket is skipped.
