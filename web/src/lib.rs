use nix_rust_template_shared::Post;
use wasm_bindgen::prelude::*;

// #[wasm_bindgen]
// pub struct Post(shared::Post);

#[wasm_bindgen]
extern "C" {
    fn alert(s: &str);
}

#[wasm_bindgen]
pub fn greet() {
    let post = Post {
        title: "title".to_string(),
        author_name: "author_name".to_string(),
        text: "text".to_string(),
    };
    alert(post.author_name.as_str());
}
