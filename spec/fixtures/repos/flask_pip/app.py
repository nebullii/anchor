import os

from flask import Flask

application = Flask(__name__)


@application.route("/")
def index():
    return "ok"


if __name__ == "__main__":
    application.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))
