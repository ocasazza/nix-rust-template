use nix_rust_template_shared::Post;
use wasm_bindgen::prelude::*;


#[wasm_bindgen]
struct PostWrapper(nix_rust_template_shared::Post);

#[wasm_bindgen]
extern "C" {
    fn alert(s: &str);
}

#[wasm_bindgen]
pub fn greet() {
    let post = Post {
        title: "Nix Rust Template".to_string(),
        author_name: "Olive Casazza".to_string(),
        text: "🚀 Blazingly Fast".to_string(),
    };
    alert(post.author_name.as_str());
}
