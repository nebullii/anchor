const express = require("express");
const app = express();

app.get("/", (_req, res) => res.send("ok"));
app.listen(4000, "127.0.0.1");
