import { createClient } from "@supabase/supabase-js";

export const SUPABASE_URL = "https://gvewzvcvmeztqyfwkgwa.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_YAVYAVXfyuBDnlK2JxLGTQ_rfnuD5_M";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
