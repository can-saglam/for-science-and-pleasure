// One-off: sample an accent colour for existing items from their source URL.
// Run: deno run -A scripts/backfill-colors.ts   (reads .supabase.env)
import { createClient } from "npm:@supabase/supabase-js@2";
import { colorFromPageUrl } from "../supabase/functions/_shared/color.ts";

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) =>
  env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim().replace(/^["']|["']$/g, "");

const supabase = createClient(get("SUPABASE_URL")!, get("SUPABASE_SERVICE_ROLE_KEY")!);

const { data: items, error } = await supabase
  .from("items")
  .select("id, title, url")
  .is("deleted_at", null)
  .is("color", null)
  .not("url", "is", null);
if (error) throw error;

console.log(`${items.length} items to try`);
let done = 0;
for (const item of items) {
  const color = await colorFromPageUrl(item.url);
  if (color) {
    const { error: updateError } = await supabase
      .from("items")
      .update({ color })
      .eq("id", item.id);
    if (updateError) throw updateError;
    done++;
    console.log(`${color}  ${item.title}`);
  } else {
    console.log(`  --    ${item.title}`);
  }
}
console.log(`Coloured ${done}/${items.length}`);
