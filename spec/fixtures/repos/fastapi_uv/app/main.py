import os

from fastapi import FastAPI

api = FastAPI()
DATABASE_URL = os.environ["DATABASE_URL"]


@api.get("/")
def root():
    return {"ok": True}
