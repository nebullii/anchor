import os

SECRET_KEY = "dev"
DEBUG = True
ALLOWED_HOSTS = []
STRIPE_KEY = os.environ["STRIPE_SECRET_KEY"]
