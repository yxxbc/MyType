# MyType 官网

静态页面，部署到 Cloudflare Workers（Workers Static Assets）。

- `public/`：页面、样式、图片、404
- `src/index.js`：把请求交给 `ASSETS` 绑定
- `wrangler.jsonc`：Worker 配置（名字 `mytype`）

## 本地预览

```sh
cd website
npx wrangler dev
```

## 部署

```sh
cd website
npx wrangler deploy
```

当前地址：<https://mytype.xynrin.cc.cd>

改 `public/` 里的内容后重新 `deploy` 即可；图片来自仓库根目录的 `docs/images/` 和 `icons/mytype/`，更新时复制到 `public/assets/`。
