const express = require("express");
const app = express();
const port = process.env.PORT || 3000;

app.get("/", (_req, res) => res.send("ok"));
app.listen(port, () => console.log(`listening on ${port}`));
